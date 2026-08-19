import AppKit
import SwiftUI

@main
struct AlpisteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    init() {
        // Handled before the UI comes up so `Alpiste --selftest` works from a terminal.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if let flag = CommandLine.arguments.firstIndex(of: "--regenerate") {
            Self.regenerate(CommandLine.arguments.dropFirst(flag + 1).first)
        }
        if CommandLine.arguments.contains("--backfill") { Self.backfill() }
    }

    /// `Alpiste --backfill`: runs the sweep the app performs on its own, now and from a
    /// terminal, over every recent note still missing its summary. Parks the main thread
    /// for the same reason `--regenerate` does.
    private static func backfill() -> Never {
        Task { @MainActor in
            let result = await Backfill.sweep()
            for file in result.filled { print("ok   filled in \(file.lastPathComponent)") }
            for failure in result.failed {
                print("FAIL \(failure.file.lastPathComponent): \(failure.reason)")
            }
            if result.filled.isEmpty && result.failed.isEmpty {
                print("ok   nothing pending")
            }
            exit(result.failed.isEmpty ? 0 : 1)
        }
        dispatchMain()
    }

    /// `Alpiste --regenerate <file.md>`: re-summarizes a saved note in place, the
    /// recovery path for when the LLM was down at recording time. Parks the main
    /// thread on purpose: the work must finish and exit before the UI comes up, and
    /// the detached task never needs the thread this blocks.
    private static func regenerate(_ path: String?) -> Never {
        guard let path else {
            print("usage: Alpiste --regenerate <file.md>")
            exit(2)
        }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        Task.detached {
            do {
                try await Notes.regenerate(file: file)
                print("ok   rewrote \(file.lastPathComponent)")
                exit(0)
            } catch {
                print("FAIL \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
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

            Button("About Alpiste") {
                // Without this the panel can open behind other apps: LSUIElement
                // means there's no Dock icon to click to bring it forward.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(options: [:])
            }

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

    static let shared = AppState()

    private(set) var phase: Phase = .idle
    private(set) var elapsed = "0:00"
    private(set) var lastNote: URL?
    /// Set by `AppDelegate` when quit arrives mid-recording/processing: suppresses
    /// modal alerts (which would block the reply) and replies to AppKit once the
    /// pipeline finishes saving.
    var pendingTermination = false

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
        // Set synchronously, before any `await`, so a second click landing before the
        // first `Task` resumes sees `isBusy` and bails instead of starting a second
        // stream that the first session's cleanup would never stop.
        guard !isRecording, !isBusy else { return }
        phase = .working("Starting…")

        Task {
            guard Recorder.hasScreenPermission() else {
                Recorder.requestScreenPermission()
                phase = .idle
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
                session = try await Recorder.start { [weak self] error in
                    Task { @MainActor in self?.streamFailed(error) }
                }
                startedAt = started
                phase = .recording
                startTicking(from: started)
            } catch {
                phase = .failed(error.localizedDescription)
                alert("Could not start recording", error.localizedDescription)
            }
        }
    }

    /// SCK stopped the stream on its own (display disconnected, permission revoked,
    /// sleep/wake). Save whatever was captured instead of leaving the UI stuck on
    /// "Recording" with nothing further ever being written.
    private func streamFailed(_ error: Error) {
        guard isRecording, session != nil else { return }  // a user-initiated stop already tore this down
        alert("Recording interrupted",
              "The capture stream stopped (\(error.localizedDescription)). "
                + "Saving what was recorded so far.")
        stop()
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

            // A summary that failed now can succeed in a few minutes, so retry on a
            // schedule instead of leaving the note for the user to notice and repair.
            if let file = result.file,
               let contents = try? String(contentsOf: file, encoding: .utf8),
               Notes.pendingSummary(markdown: contents) {
                Backfill.scheduleRetries()
            }

            if pendingTermination { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    /// A backfill sweep filled in a note after the fact. Point "Open …" at it and say so
    /// in the menu, but never while something is live: overwriting a recording's status
    /// line would be worse than staying quiet until it finishes.
    func noteBackfilled(_ file: URL) {
        lastNote = file
        switch phase {
        case .idle, .done, .failed: phase = .done(file)
        case .recording, .working: break
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
        // A modal here while AppKit is waiting on applicationShouldTerminate would
        // block the reply that lets the app actually quit; log instead.
        guard !pendingTermination else {
            NSLog("alpiste: \(title) — \(message)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Keeps a recording (and the notes pipeline that follows it) from being cut off by
/// Cmd-Q: `applicationShouldTerminate` defers the quit and lets `AppState` finish
/// saving before AppKit is allowed to tear the app down.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Catches notes left unsummarized by an earlier run: the app may well have been
        // quit before its retry schedule had a chance to fire.
        Backfill.sweepAtLaunch()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        switch state.phase {
        case .recording:
            state.pendingTermination = true
            state.stop()
            return .terminateLater
        case .working:
            state.pendingTermination = true
            return .terminateLater
        default:
            return .terminateNow
        }
    }
}

/// The one runnable check: asserts the pure logic that the rest of the app depends on.
/// Run with `Alpiste.app/Contents/MacOS/Alpiste --selftest`.
enum SelfTest {
    /// Parks the main thread on purpose: `checks()` runs real ffmpeg processes through
    /// the async `Tool.run`, so the check needs its own task; nothing after this needs
    /// the thread it blocks.
    static func run() -> Never {
        Task.detached {
            let failures = await checks()
            print(failures.isEmpty ? "\nPASS" : "\nFAIL (\(failures.count))")
            exit(failures.isEmpty ? 0 : 1)
        }
        dispatchMain()
    }

    private static func checks() async -> [String] {
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

        // A silent participant and a dead mic produce identical audio, so the file has to
        // say which sources were captured.
        let oneSource = Notes.markdown(title: "t", notes: nil, transcript: "x",
                                       audioFile: "a.m4a", sources: "system audio", problems: [])
        expect(oneSource.contains("system audio"), "markdown: names the captured sources")
        expect(!oneSource.contains("microphone"), "markdown: omits sources that were absent")

        // Regeneration: a degraded file must yield its transcript back, minus the
        // failure noise, so `--regenerate` can rebuild it.
        let failed = Notes.markdown(title: "t", notes: nil, transcript: "raw text",
                                    audioFile: "a.m4a", sources: "system audio",
                                    problems: ["HTTP 503: overloaded"])
        if let parts = Notes.split(markdown: failed) {
            expect(parts.transcript == "raw text", "split: recovers the transcript")
            expect(parts.header.contains("a.m4a"), "split: keeps the audio line")
            expect(!parts.header.contains("HTTP 503"), "split: drops the problems block")
            expect(!parts.header.contains("No notes were generated"), "split: drops the placeholder")
        } else {
            expect(false, "split: parses a degraded note file")
        }
        let healthy = Notes.markdown(title: "t", notes: "## Summary\n- p",
                                     transcript: "raw text", audioFile: "a.m4a", problems: [])
        if let parts = Notes.split(markdown: healthy) {
            let rebuilt = parts.header + "\n\n## Summary\n- p\n\n---\n\n## Transcript\n\n"
                + parts.transcript + "\n"
            expect(rebuilt == healthy, "split: round-trips a healthy note file")
        } else {
            expect(false, "split: parses a healthy note file")
        }
        expect(Notes.split(markdown: "# no divider") == nil, "split: nil without a divider")

        // What the backfill sweep keys off: retry the notes that are missing, leave the
        // rest alone. A wrong answer here either loses summaries or rewrites good files.
        expect(Notes.pendingSummary(markdown: failed),
               "pendingSummary: true when the LLM failed but the transcript survived")
        expect(!Notes.pendingSummary(markdown: healthy),
               "pendingSummary: false when the note already has its summary")
        expect(!Notes.pendingSummary(markdown: "# no divider"),
               "pendingSummary: false without a transcript section")
        // Transcription itself failed, so there is nothing to re-summarize; sweeping this
        // file forever would just burn API calls.
        let noTranscript = Notes.markdown(title: "t", notes: nil, transcript: "",
                                          audioFile: "a.m4a", problems: ["Transcription failed"])
        expect(!Notes.pendingSummary(markdown: noTranscript),
               "pendingSummary: false when there is no transcript to summarize")

        expect(Notes.stamp(Date(timeIntervalSince1970: 0)).count == 15, "stamp: YYYY-MM-DD-HHMM")
        // Guards against a non-Gregorian system calendar (Japanese, Buddhist, ...)
        // silently turning "yyyy" into an era year and breaking the filename format.
        expect(Notes.stamp(Date(timeIntervalSince1970: 0)).allSatisfy { "0123456789-".contains($0) },
               "stamp: digits and dashes regardless of system calendar")

        expect(Notes.uniqueStem("x") { $0 == "x" || $0 == "x-2" } == "x-3",
               "uniqueStem: skips names that are already taken")
        expect(Notes.uniqueStem("y") { _ in false } == "y",
               "uniqueStem: keeps an untaken name as-is")

        expect(Tool.find("ffmpeg") != nil, "tools: ffmpeg found without a login PATH")

        // Actually run the mixer on synthetic audio. Asserting the argument array would
        // only restate assumptions; the real failure here was ffmpeg refusing a two-output
        // filtergraph, which nothing but a real invocation catches.
        if let ffmpeg = Tool.find("ffmpeg") {
            func mixCheck(_ label: String, sources: Int) async {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("alpiste-selftest-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: dir) }
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                let tones = ["system.caf": "sine=frequency=440:duration=3",
                             "mic.caf": "sine=frequency=880:duration=2"]
                var made: [URL] = []
                for (name, tone) in tones.sorted(by: { $0.key < $1.key }).prefix(sources) {
                    let url = dir.appendingPathComponent(name)
                    try? await Tool.run(ffmpeg, ["-y", "-nostdin", "-f", "lavfi", "-i", tone,
                                                 "-c:a", "pcm_f32le", url.path],
                                        in: dir, label: "gen")
                    made.append(url)
                }
                let capture = Recorder.Capture(directory: dir,
                                               systemAudio: made.first { $0.lastPathComponent == "system.caf" },
                                               microphone: made.first { $0.lastPathComponent == "mic.caf" })
                do {
                    let mixed = try await Notes.mix(capture)
                    func size(_ url: URL) -> Int {
                        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    }
                    expect(size(mixed.m4a) > 0, "mix/\(label): produced a non-empty m4a")
                    expect(size(mixed.wav16k) > 0, "mix/\(label): produced a non-empty 16k wav")
                    // ponytail: no clipping assertion here. Synthetic tones don't reach
                    // 0 dBFS through amix, so the check passed with and without the
                    // limiter: a test that cannot fail is worse than none. Verifying the
                    // limiter needs a real hot recording, not lavfi.
                } catch {
                    expect(false, "mix/\(label): \(error.localizedDescription)")
                }
            }
            await mixCheck("system only", sources: 1)
            await mixCheck("system + mic", sources: 2)
        }
        let whisper = Tool.find("whisper-cli") != nil
        print("\(whisper ? "ok  " : "note") tools: whisper-cli \(whisper ? "found" : "missing, run scripts/setup.sh")")
        let model = FileManager.default.fileExists(atPath: Notes.modelURL.path)
        print("\(model ? "ok  " : "note") model: ggml-medium.bin \(model ? "present" : "missing, run scripts/setup.sh")")

        return failures
    }
}
