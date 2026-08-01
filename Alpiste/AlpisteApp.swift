import AppKit
import SwiftUI

@main
struct AlpisteApp: App {
    @State private var state = AppState()

    init() {
        // Handled before the UI comes up so `Alpiste --selftest` works from a terminal.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(state.statusText)

            Divider()

            if state.isRecording {
                Button("Stop Recording") { state.stop() }
                    .keyboardShortcut("r")
            } else {
                Button("Start Recording") { state.start() }
                    .keyboardShortcut("r")
                    .disabled(state.isBusy)
            }

            if let last = state.lastNote {
                Button("Open \(last.lastPathComponent)") { NSWorkspace.shared.open(last) }
            }
            Button("Open Notes Folder") {
                try? FileManager.default.createDirectory(at: Notes.outputDirectory,
                                                         withIntermediateDirectories: true)
                NSWorkspace.shared.open(Notes.outputDirectory)
            }

            Divider()

            Button("Quit Alpiste") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            // Label shows the elapsed time next to the icon while recording.
            if state.isRecording {
                Label(state.elapsed, systemImage: "record.circle.fill")
            } else {
                Image(systemName: state.isBusy ? "hourglass" : "waveform")
            }
        }
    }
}

@MainActor
@Observable
final class AppState {
    enum Phase {
        case idle
        case recording
        case working(String)
        case done(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var elapsed = "0:00"
    private(set) var lastNote: URL?

    private var session: Recorder.Session?
    private var startedAt: Date?
    private var ticker: Timer?

    var isRecording: Bool { if case .recording = phase { true } else { false } }
    var isBusy: Bool { if case .working = phase { true } else { false } }

    var statusText: String {
        switch phase {
        case .idle: "Ready"
        case .recording: "Recording \(elapsed)"
        case .working(let step): step
        case .done(let url): "Saved \(url.lastPathComponent)"
        case .failed(let message): "Failed: \(message)"
        }
    }

    // MARK: - Recording

    func start() {
        Task {
            guard Recorder.hasScreenPermission() else {
                Recorder.requestScreenPermission()
                alert("Screen Recording permission needed",
                      "Alpiste needs Screen Recording to capture the meeting's audio.\n\n"
                        + "Enable it in System Settings > Privacy & Security > Screen Recording, "
                        + "then quit and reopen Alpiste. macOS only applies this permission on relaunch.")
                return
            }

            if await !Recorder.requestMicPermission() {
                alert("Microphone is off",
                      "Alpiste will record the meeting's audio but not your voice.\n\n"
                        + "Enable the microphone in System Settings > Privacy & Security > Microphone.")
            }

            do {
                let started = Date()
                session = try await Recorder.start()
                startedAt = started
                phase = .recording
                startTicking(from: started)
            } catch {
                phase = .failed(error.localizedDescription)
                alert("Could not start recording", error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let session, let startedAt else { return }
        self.session = nil
        stopTicking()
        phase = .working("Mixing audio…")

        Task {
            let capture = await session.stop()
            // Hops back to the main actor to publish each step of the pipeline.
            let result = await Notes.process(capture, startedAt: startedAt) { step in
                Task { @MainActor in
                    if case .working = self.phase { self.phase = .working(step) }
                }
            }

            if let file = result.file {
                lastNote = file
                phase = .done(file)
                if !result.problems.isEmpty {
                    alert("Saved with warnings",
                          "\(file.lastPathComponent) was written, but:\n\n"
                            + result.problems.map { "• \($0)" }.joined(separator: "\n"))
                }
            } else {
                let message = result.problems.joined(separator: "\n")
                phase = .failed(message)
                alert("Could not save notes", message)
            }
        }
    }

    // MARK: - Helpers

    private func startTicking(from start: Date) {
        elapsed = "0:00"
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let seconds = Int(Date().timeIntervalSince(start))
                self.elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// The one runnable check: asserts the pure logic that the rest of the app depends on.
/// Run with `Alpiste.app/Contents/MacOS/Alpiste --selftest`.
enum SelfTest {
    static func run() -> Never {
        var failures: [String] = []
        func expect(_ condition: Bool, _ what: String) {
            if !condition { failures.append(what) }
            print("\(condition ? "ok  " : "FAIL") \(what)")
        }

        let env = Env.parse("""
            # a comment
            GEMINI_API_KEY=abc123

              export GROQ_API_KEY = "quoted value"
            OPENAI_API_KEY='single'
            WEIRD=a=b=c
            #GEMINI_MODEL=commented-out
            NOEQUALS
            """)
        expect(env["GEMINI_API_KEY"] == "abc123", "env: plain value")
        expect(env["GROQ_API_KEY"] == "quoted value", "env: export prefix, spaces, double quotes")
        expect(env["OPENAI_API_KEY"] == "single", "env: single quotes")
        expect(env["WEIRD"] == "a=b=c", "env: splits on the first = only")
        expect(env["GEMINI_MODEL"] == nil, "env: skips commented lines")
        expect(env["NOEQUALS"] == nil, "env: skips lines without =")

        let full = Notes.markdown(title: "Meeting Notes: 2026-07-31 22:14",
                                  notes: "## Summary\n- point",
                                  transcript: "hello world",
                                  audioFile: "2026-07-31-2214.m4a",
                                  problems: [])
        expect(full.hasPrefix("# Meeting Notes: 2026-07-31 22:14"), "markdown: title first")
        expect(full.contains("2026-07-31-2214.m4a"), "markdown: references the audio file")
        let body = full.components(separatedBy: "\n---\n")
        expect(body.count == 2, "markdown: exactly one divider")
        expect(body.first?.contains("## Summary") == true, "markdown: notes above the divider")
        expect(body.last?.contains("hello world") == true, "markdown: transcript below the divider")

        // The data-loss guard: a failed pipeline still produces a usable file.
        let degraded = Notes.markdown(title: "t", notes: nil, transcript: "raw text",
                                      audioFile: "a.m4a", problems: ["Gemini exploded"])
        expect(degraded.contains("raw text"), "markdown: keeps the transcript when notes fail")
        expect(degraded.contains("Gemini exploded"), "markdown: surfaces the problem")

        expect(Notes.stamp(Date(timeIntervalSince1970: 0)).count == 15, "stamp: YYYY-MM-DD-HHMM")

        expect(Tool.find("ffmpeg") != nil, "tools: ffmpeg found without a login PATH")

        // Actually run the mixer on synthetic audio. Asserting the argument array would
        // only restate assumptions; the real failure here was ffmpeg refusing a two-output
        // filtergraph, which nothing but a real invocation catches.
        if let ffmpeg = Tool.find("ffmpeg") {
            func mixCheck(_ label: String, sources: Int) {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("alpiste-selftest-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: dir) }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let tones = ["system.caf": "sine=frequency=440:duration=3",
                             "mic.caf": "sine=frequency=880:duration=2"]
                var made: [URL] = []
                for (name, tone) in tones.sorted(by: { $0.key < $1.key }).prefix(sources) {
                    let url = dir.appendingPathComponent(name)
                    try? Tool.run(ffmpeg, ["-y", "-nostdin", "-f", "lavfi", "-i", tone,
                                           "-c:a", "pcm_f32le", url.path],
                                  in: dir, label: "gen")
                    made.append(url)
                }
                let capture = Recorder.Capture(directory: dir,
                                               systemAudio: made.first { $0.lastPathComponent == "system.caf" },
                                               microphone: made.first { $0.lastPathComponent == "mic.caf" })
                do {
                    let mixed = try Notes.mix(capture)
                    func size(_ url: URL) -> Int {
                        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    }
                    expect(size(mixed.m4a) > 0, "mix/\(label): produced a non-empty m4a")
                    expect(size(mixed.wav16k) > 0, "mix/\(label): produced a non-empty 16k wav")
                } catch {
                    expect(false, "mix/\(label): \(error.localizedDescription)")
                }
            }
            mixCheck("system only", sources: 1)
            mixCheck("system + mic", sources: 2)
        }
        let whisper = Tool.find("whisper-cli") != nil
        print("\(whisper ? "ok  " : "note") tools: whisper-cli \(whisper ? "found" : "missing, run scripts/setup.sh")")
        let model = FileManager.default.fileExists(atPath: Notes.modelURL.path)
        print("\(model ? "ok  " : "note") model: ggml-medium.bin \(model ? "present" : "missing, run scripts/setup.sh")")

        print(failures.isEmpty ? "\nPASS" : "\nFAIL (\(failures.count))")
        exit(failures.isEmpty ? 0 : 1)
    }
}
