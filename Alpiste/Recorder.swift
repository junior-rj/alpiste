import AppKit
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
        case timedOut(String, TimeInterval)

        var errorDescription: String? {
            switch self {
            case .noDisplay:
                "No display available to capture audio from."
            case .screenRecordingDenied:
                "Screen Recording permission is required to capture system audio. "
                    + "Grant it in System Settings > Privacy & Security > Screen Recording, "
                    + "then relaunch Alpiste."
            case .timedOut(let what, let seconds):
                "\(what) did not answer within \(Int(seconds))s. "
                    + "The capture daemon may be wedged; try again."
            }
        }
    }

    /// Ceilings for the two ScreenCaptureKit calls that can hang without ever returning.
    /// Generous: a cold `replayd` on a busy machine is slow, and cutting a start that was
    /// merely late would be worse than the wait.
    static let contentTimeout: TimeInterval = 20
    static let startTimeout: TimeInterval = 45

    static func hasScreenPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Both of these raise a system dialog, so both activate first. Alpiste is
    /// `LSUIElement`: with no Dock icon there is nothing to click to bring a dialog
    /// forward, and on 2026-08-24 the calendar prompt opened behind the meeting window
    /// and was never answered. The microphone one is worse, because `start()` stays
    /// suspended on it with `isBusy` true, which also disables the menu item and the
    /// watcher until the app is relaunched.
    @MainActor
    @discardableResult
    static func requestScreenPermission() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return CGRequestScreenCaptureAccess()
    }

    @MainActor
    static func requestMicPermission() async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts capturing. Call `stop()` on the returned session to finish. `onStreamError`
    /// fires if SCK stops the stream on its own mid-meeting (display disconnected,
    /// permission revoked, sleep/wake) so the caller can salvage whatever was captured
    /// instead of leaving the UI showing "Recording" forever.
    static func start(onStreamError: @escaping @Sendable (Error) -> Void) async throws -> Session {
        guard hasScreenPermission() else { throw Failure.screenRecordingDenied }

        // Everything SCK gives us here is non-Sendable, so the filter is built inside the
        // deadline and only the box crosses back out.
        let filter = try await withDeadline(contentTimeout, "shareable content") {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw Failure.noDisplay }
            return FilterBox(filter: SCContentFilter(display: display, excludingWindows: []))
        }.filter

        // Application Support rather than the temp directory: a multi-hour meeting can
        // reach several GB, and macOS is free to purge temporaryDirectory under disk
        // pressure, which is exactly when a large in-progress recording is most at risk.
        let directory = Notes.supportDirectory
            .appendingPathComponent("captures/alpiste-\(UUID().uuidString)", isDirectory: true)
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

        let tap = AudioTap(directory: directory, onStop: onStreamError)
        let stream = SCStream(filter: filter, configuration: config, delegate: tap)

        let queue = DispatchQueue(label: "com.sparrow.alpiste.audio")
        try stream.addStreamOutput(tap, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(tap, type: .microphone, sampleHandlerQueue: queue)

        do {
            // A wedged replayd or WindowServer can leave `startCapture` outstanding
            // forever, and the state machine parks in "Starting…" with the menu item
            // disabled and the watcher unable to propose anything. If the deadline wins,
            // the call is abandoned but the `catch` below still stops the stream, which
            // is what keeps a late success from becoming an orphaned replayd session.
            let box = StreamBox(stream: stream)
            try await withDeadline(startTimeout, "startCapture") {
                try await box.stream.startCapture()
            }
        } catch {
            // A start can fail after SCK has already begun delivering: on 2026-08-27 it
            // wrote five seconds of system.caf and then threw "Stream failed to start
            // microphone". Nothing ever salvages a capture that never became a session,
            // so tear it down here or the directory accumulates.
            //
            // The stopCapture is not optional. That same day the 0.5.4 dropped the failed
            // stream without it, and replayd kept the capture session alive for hours
            // with a dead client, then grabbed the microphone on the next device wake;
            // quitting the app did not release it. Whether replayd honours the stop is
            // exactly what the log line is for, so the result is never swallowed.
            do {
                try await stream.stopCapture()
                Log.write("capture start failed — \(error.localizedDescription); stopCapture ok")
            } catch let stopError {
                Log.write("capture start failed — \(error.localizedDescription); "
                          + "stopCapture also failed — \(stopError.localizedDescription)")
            }
            _ = tap.finish()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return Session(stream: stream, tap: tap, directory: directory)
    }

    /// One-way handoffs of ScreenCaptureKit types that are not marked Sendable, so the
    /// deadline race below can hold them. Nothing mutates them and nothing else reads
    /// them, same reasoning as `Session`.
    private struct FilterBox: @unchecked Sendable { let filter: SCContentFilter }
    private struct StreamBox: @unchecked Sendable { let stream: SCStream }

    /// Runs `work` with a ceiling, and **abandons** it if the ceiling is reached instead
    /// of waiting for it to unwind. That is the whole point: the calls this guards hang
    /// inside a daemon that will not honour cancellation, so a `TaskGroup` would be no
    /// help, since the group awaits every child before its scope can exit.
    ///
    /// Whoever lands first wins; `Landing` drops the loser on the floor.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval, _ what: String,
        _ work: @escaping @Sendable () async throws -> T) async throws -> T {

        let landing = Landing<T>()
        Task {
            do { landing.settle(.success(try await work())) }
            catch { landing.settle(.failure(CapturedError(error))) }
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            Log.write("\(what) hit its \(Int(seconds))s ceiling and was abandoned")
            landing.settle(.failure(CapturedError(Failure.timedOut(what, seconds))))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            landing.wait(continuation)
        }
    }

    /// What comes back out of `withDeadline` when the work throws. An error crossing a
    /// task boundary has to be Sendable and `any Error` is not, so the message travels
    /// instead of the value. Everything downstream reads `localizedDescription` and
    /// nothing switches on the type, so nothing is lost.
    struct CapturedError: LocalizedError, Sendable {
        let errorDescription: String?
        init(_ error: any Error) { errorDescription = error.localizedDescription }
    }

    /// A continuation exactly one of two racers may resume, holding the result when it
    /// lands before anyone is waiting for it.
    private final class Landing<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var result: Result<T, CapturedError>?
        private var settled = false

        func wait(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            let landed = result
            self.continuation = landed == nil ? continuation : nil
            lock.unlock()
            if let landed { Self.deliver(landed, to: continuation) }
        }

        func settle(_ result: Result<T, CapturedError>) {
            lock.lock()
            guard !settled else { return lock.unlock() }
            settled = true
            let waiting = continuation
            continuation = nil
            self.result = result
            lock.unlock()
            if let waiting { Self.deliver(result, to: waiting) }
        }

        /// Unpacked rather than handed over whole: `resume(with:)` wants a Result whose
        /// failure type is `any Error`, which is not Sendable and so cannot cross to here.
        private static func deliver(_ result: Result<T, CapturedError>,
                                    to continuation: CheckedContinuation<T, any Error>) {
            switch result {
            case .success(let value): continuation.resume(returning: value)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
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
    private let onStop: @Sendable (Error) -> Void

    init(directory: URL, onStop: @escaping @Sendable (Error) -> Void) {
        self.directory = directory
        self.onStop = onStop
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
        lock.lock()
        let alreadyStopped = stopped
        lock.unlock()
        // A stop the user asked for already tore this down; only a stream that died
        // on its own needs to be reported upward.
        if !alreadyStopped { onStop(error) }
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
