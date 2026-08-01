import AVFoundation
import ScreenCaptureKit

/// Captures system audio + microphone into two separate CAF files.
///
/// ScreenCaptureKit delivers system audio and mic on *different* output types, in
/// *different* formats (the mic uses its device-native format), and never mixes them.
/// SCRecordingOutput can't help: it requires a video codec. So each source gets its own
/// file and `Notes` mixes them with one ffmpeg call, which keeps all the drift and
/// resampling logic out of this file.
///
/// CAF rather than WAV: it accepts any format without conversion and has no 4 GB ceiling,
/// so a long meeting can't silently truncate.
enum Recorder {
    struct Capture {
        let directory: URL
        let systemAudio: URL?
        let microphone: URL?
    }

    enum Failure: LocalizedError {
        case noDisplay
        case screenRecordingDenied

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                "No display available to capture audio from."
            case .screenRecordingDenied:
                "Screen Recording permission is required to capture system audio. "
                    + "Grant it in System Settings > Privacy & Security > Screen Recording, "
                    + "then relaunch Alpiste."
            }
        }
    }

    static func hasScreenPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestScreenPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts capturing. Call `stop()` on the returned session to finish.
    static func start() async throws -> Session {
        guard hasScreenPermission() else { throw Failure.screenRecordingDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw Failure.noDisplay }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpiste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = true
        // Without this the app's own output would loop back into the recording.
        config.excludesCurrentProcessAudio = true
        // SCK has no audio-only mode: a display filter is mandatory, so we take the
        // smallest, slowest video surface it will accept and throw every frame away.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 6

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let tap = AudioTap(directory: directory)
        let stream = SCStream(filter: filter, configuration: config, delegate: tap)

        let queue = DispatchQueue(label: "com.sparrow.alpiste.audio")
        try stream.addStreamOutput(tap, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(tap, type: .microphone, sampleHandlerQueue: queue)

        try await stream.startCapture()
        return Session(stream: stream, tap: tap, directory: directory)
    }

    /// `SCStream` isn't marked Sendable, but `stopCapture()` is safe to call from any
    /// thread and this handoff is one-way: the main actor creates it, then hands it to a
    /// single background task to stop. No shared mutation.
    struct Session: @unchecked Sendable {
        let stream: SCStream
        let tap: AudioTap
        let directory: URL

        func stop() async -> Capture {
            try? await stream.stopCapture()
            return tap.finish()
        }
    }
}

/// Receives SCK sample buffers and appends them to per-source audio files.
///
/// All three output types share one serial queue, so the callbacks are already
/// serialized; the lock additionally guards `finish()` racing with a late buffer.
final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var writers: [SCStreamOutputType: AVAudioFile] = [:]
    private var stopped = false

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    private func filename(for type: SCStreamOutputType) -> String? {
        switch type {
        case .audio: "system.caf"
        case .microphone: "mic.caf"
        default: nil
        }
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard let name = filename(for: type) else { return }  // .screen frames are discarded
        guard sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: asbd),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0
        else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }

        let file: AVAudioFile
        if let existing = writers[type] {
            file = existing
        } else {
            do {
                file = try AVAudioFile(forWriting: directory.appendingPathComponent(name),
                                       settings: format.settings,
                                       commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
                writers[type] = file
            } catch {
                NSLog("alpiste: could not open \(name): \(error)")
                return
            }
        }

        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format,
                                                 bufferListNoCopy: list.unsafePointer)
                else { return }
                try file.write(from: pcm)
            }
        } catch {
            NSLog("alpiste: write to \(name) failed: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("alpiste: stream stopped with error: \(error)")
    }

    /// Closes the files and reports which ones actually received audio.
    func finish() -> Recorder.Capture {
        lock.lock()
        stopped = true
        // Dropping the AVAudioFile references flushes and closes them.
        let written = Set(writers.keys)
        writers.removeAll()
        lock.unlock()

        func url(_ type: SCStreamOutputType, _ name: String) -> URL? {
            guard written.contains(type) else { return nil }
            let candidate = directory.appendingPathComponent(name)
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size > 0 ? candidate : nil
        }

        return Recorder.Capture(directory: directory,
                                systemAudio: url(.audio, "system.caf"),
                                microphone: url(.microphone, "mic.caf"))
    }
}
