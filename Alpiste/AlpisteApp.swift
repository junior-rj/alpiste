import AppKit
import EventKit
import SwiftUI

@main
struct AlpisteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared

    init() {
        // Handled before the UI comes up so `Alpiste --selftest` works from a terminal.
        if CommandLine.arguments.contains("--selftest") { SelfTest.run() }
        if CommandLine.arguments.contains("--regenerate") {
            Self.regenerate(Self.operand(after: "--regenerate", in: CommandLine.arguments))
        }
        if CommandLine.arguments.contains("--retranscribe") {
            Self.retranscribe(Self.operand(after: "--retranscribe", in: CommandLine.arguments))
        }
        if CommandLine.arguments.contains("--backfill") { Self.backfill() }
    }

    /// Pure: the path that follows `flag`, or nil when what follows is another flag.
    /// Without the second half, `Alpiste --regenerate --backfill` goes looking for a file
    /// named "--backfill" and reports the wrong failure. Covered by `--selftest`.
    nonisolated static func operand(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              let next = arguments.dropFirst(index + 1).first,
              !next.hasPrefix("--")
        else { return nil }
        return next
    }

    /// `Alpiste --backfill`: runs the sweep the app performs on its own, now and from a
    /// terminal, over every recent note still missing its summary. Parks the main thread
    /// for the same reason `--regenerate` does.
    private static func backfill() -> Never {
        Log.startup("--backfill")
        Task { @MainActor in
            let result = await Backfill.sweep()
            for file in result.filled { print("ok   filled in \(file.lastPathComponent)") }
            for failure in result.failed {
                print("FAIL \(failure.file.lastPathComponent): \(failure.reason)")
            }
            if result.filled.isEmpty && result.failed.isEmpty {
                print("ok   nothing pending")
            }
            Log.flush()
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
            Log.flush()
            exit(2)
        }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        Log.startup("--regenerate \(file.lastPathComponent)")
        Task.detached {
            do {
                try await Notes.regenerate(file: file)
                Log.write("regenerate: rewrote \(file.lastPathComponent)")
                print("ok   rewrote \(file.lastPathComponent)")
                Log.flush()
                exit(0)
            } catch {
                Log.write("regenerate: failed — \(error.localizedDescription)")
                print("FAIL \(error.localizedDescription)")
                Log.flush()
                exit(1)
            }
        }
        dispatchMain()
    }

    /// `Alpiste --retranscribe <file.md>`: throws the saved transcript away and builds
    /// a new one from the `.m4a` beside the note, then re-summarizes. Recovery for a
    /// transcript the decoder looped on, which `--regenerate` cannot fix because it
    /// reuses whatever transcript it finds. Parks the main thread like `--regenerate`.
    private static func retranscribe(_ path: String?) -> Never {
        guard let path else {
            print("usage: Alpiste --retranscribe <file.md>")
            Log.flush()
            exit(2)
        }
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        Log.startup("--retranscribe \(file.lastPathComponent)")
        Task.detached {
            do {
                let problems = try await Notes.retranscribe(file: file)
                Log.write("retranscribe: rewrote \(file.lastPathComponent)"
                            + (problems.isEmpty ? " cleanly"
                               : " with \(problems.count) problem(s): \(problems.joined(separator: "; "))"))
                print("ok   rewrote \(file.lastPathComponent)")
                for problem in problems { print("note \(problem)") }
                Log.flush()
                exit(0)
            } catch {
                Log.write("retranscribe: failed — \(error.localizedDescription)")
                print("FAIL \(error.localizedDescription)")
                Log.flush()
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

            Toggle("Auto-start on Meetings", isOn: Binding(
                get: { state.autoStartOnMeetings },
                set: { state.setAutoStartOnMeetings($0) }))

            // Recording still works without the calendar, so this is a note, not an alarm.
            // The two failures need opposite actions: one this app can still resolve with a
            // dialog, one only System Settings can.
            if state.autoStartOnMeetings {
                switch state.meetingCalendarStatus {
                case .available:
                    EmptyView()
                case .notAsked:
                    Button("Allow Calendar Access…") { state.requestCalendarAccess() }
                case .blocked:
                    Button("Calendar Access Blocked — Open Settings") {
                        MeetingCalendar.openSystemSettings()
                    }
                }
            }

            if let last = state.lastNote {
                Button("Open \(last.lastPathComponent)") { NSWorkspace.shared.open(last) }
            }
            Button("Open Notes Folder") {
                try? FileManager.default.createDirectory(at: Notes.outputDirectory,
                                                         withIntermediateDirectories: true)
                NSWorkspace.shared.open(Notes.outputDirectory)
            }
            // The answer to "it showed an error and I couldn't capture it": the log is a
            // plain text file the user can open and hand over as-is.
            Button("Open Log") { NSWorkspace.shared.open(Log.flushed()) }

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
        /// Saved, but the summary is missing and the backfill is going to try again.
        /// Distinct from `failed` because nothing is lost yet and no alert is warranted.
        case retrying(URL)
        /// Saved and recovered by a backfill pass after the recording had finished.
        case recovered(URL)
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

    /// The calendar title of the recording underway, when the meeting watcher supplied
    /// one. Cleared with every stop so a later manual recording cannot inherit it.
    private var meetingTitle: String?

    private var session: Recorder.Session?
    private var startedAt: Date?
    private var ticker: Timer?
    /// A stream that died in the window between `Recorder.start` returning and the phase
    /// becoming `.recording`, where `streamFailed` has no session to stop yet. Held here
    /// so `start()` can act on it instead of the UI showing a timer against a dead stream.
    private var pendingStreamError: (any Error)?

    var isRecording: Bool { if case .recording = phase { true } else { false } }
    var isBusy: Bool { if case .working = phase { true } else { false } }

    var statusText: String {
        switch phase {
        case .idle: "Ready"
        case .recording: "Recording \(elapsed)"
        case .working(let step): step
        case .done(let url): "Saved \(url.lastPathComponent)"
        case .retrying(let url): "Saved \(url.lastPathComponent) — notes pending, retrying"
        case .recovered(let url): "Recovered notes for \(url.lastPathComponent)"
        case .failed(let message): "Failed: \(message)"
        }
    }

    // MARK: - Recording

    func start(title: String? = nil) {
        // Set synchronously, before any `await`, so a second click landing before the
        // first `Task` resumes sees `isBusy` and bails instead of starting a second
        // stream that the first session's cleanup would never stop.
        guard !isRecording, !isBusy else { return }
        meetingTitle = title
        phase = .working("Starting…")

        Task {
            guard Recorder.hasScreenPermission() else {
                Recorder.requestScreenPermission()
                phase = .idle
                alert("Screen Recording permission needed",
                      "Alpiste needs Screen Recording to capture the meeting's audio.\n\n"
                        + "Enable it in System Settings > Privacy & Security > Screen Recording, "
                        + "then quit and reopen Alpiste. macOS only applies this permission on relaunch.")
                finishTerminationIfPending()
                return
            }

            // Asking has to happen before the stream starts, since this is what raises the
            // TCC dialog, but *warning* about a denial must not: `alert` is modal, and on
            // 0.5.7 it held the start until someone clicked OK, blocking the very recording
            // the text promises will still happen. Warn once there is a stream.
            let micDenied = await !Recorder.requestMicPermission()

            let onStreamError: @Sendable (Error) -> Void = { [weak self] error in
                Task { @MainActor in self?.streamFailed(error) }
            }
            do {
                let started = Date()
                do {
                    session = try await Recorder.start(onStreamError: onStreamError)
                } catch {
                    // One retry, not a loop. On 2026-08-27 SCK threw "Stream failed to
                    // start microphone" 100 s after a lid-open wake, and the retry the
                    // user made by hand six seconds later worked. Left alone, a meeting
                    // nobody was watching would simply not have been recorded.
                    Log.write("recording start failed once — \(error.localizedDescription), retrying in 2s")
                    try await Task.sleep(for: .seconds(2))
                    session = try await Recorder.start(onStreamError: onStreamError)
                }
                startedAt = started
                phase = .recording
                startTicking(from: started)
                Log.write("recording started")
                if micDenied {
                    alert("Microphone is off",
                          "Alpiste is recording the meeting's audio but not your voice.\n\n"
                            + "Enable the microphone in System Settings > Privacy & Security > Microphone.")
                }
                // The stream died while we were still setting up: act on it now that there
                // is a session to tear down, rather than leaving a ticking timer against it.
                if let died = pendingStreamError {
                    pendingStreamError = nil
                    streamFailed(died)
                    return
                }
                // Cmd-Q landed inside the "Starting…" window. There is a recording now, so
                // honour the quit the way `applicationShouldTerminate` would have: stop and
                // let the pipeline save, and `stop()` answers AppKit when it is done.
                if pendingTermination {
                    Log.write("quit requested while starting — stopping and saving")
                    stop()
                }
            } catch {
                Log.write("recording could not start — \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
                alert("Could not start recording", error.localizedDescription)
                finishTerminationIfPending()
            }
        }
    }

    /// SCK stopped the stream on its own (lid closed, display disconnected, permission
    /// revoked, sleep/wake). Save whatever was captured instead of leaving the UI stuck
    /// on "Recording" with nothing further ever being written.
    ///
    /// `stop()` goes before the alert on purpose: `alert` is modal and blocks until
    /// dismissed. With the order reversed, the two lid-close cases of 2026-08-26/27 sat
    /// with the capture unprocessed until the lid opened and OK was clicked (47 min the
    /// first time), and a shutdown in between would have left it stranded in captures/.
    private func streamFailed(_ error: Error) {
        guard session != nil else { return }  // a user-initiated stop already tore this down
        guard isRecording else {
            // Between `Recorder.start` returning and the phase becoming `.recording`:
            // `stop()` would find nothing to stop and the death would vanish, leaving the
            // menu counting time against a stream that is already gone.
            pendingStreamError = error
            return
        }
        Log.write("capture stream stopped on its own — \(error.localizedDescription)")
        stop()
        alert("Recording interrupted",
              "The capture stream stopped (\(error.localizedDescription)). "
                + "What was recorded up to that point is being saved. "
                + "Closing the lid mid-recording is the usual cause.")
    }

    func stop() {
        guard let session, let startedAt else {
            // Nothing to save. A quit waiting on this would otherwise wait forever.
            finishTerminationIfPending()
            return
        }
        self.session = nil
        pendingStreamError = nil
        let title = meetingTitle
        meetingTitle = nil
        stopTicking()
        phase = .working("Mixing audio…")

        Log.write("recording stopped after \(elapsed), starting the pipeline")

        Task {
            let capture = await session.stop()
            // Hops back to the main actor to publish each step of the pipeline.
            let result = await Notes.process(capture, startedAt: startedAt,
                                             title: title) { step in
                Log.write("pipeline: \(step)")
                Task { @MainActor in
                    if case .working = self.phase { self.phase = .working(step) }
                }
            }

            if let file = result.file {
                lastNote = file

                // A summary that failed now can succeed in a few minutes, so retry on a
                // schedule instead of leaving the note for the user to notice and repair.
                let contents = try? String(contentsOf: file, encoding: .utf8)
                let summaryPending = contents.map(Notes.pendingSummary) ?? false
                if summaryPending { Backfill.scheduleRetries() }

                // Only the problems a retry cannot fix are worth interrupting for. On
                // 2026-08-20 a modal fired the instant three further attempts had been
                // scheduled, one of them succeeded six minutes later, and the alarm was
                // never taken back — so the meeting read as lost all day when it wasn't.
                let unrecoverable = Notes.problemsWorthAlerting(result.problems,
                                                               summaryPending: summaryPending)
                phase = summaryPending && unrecoverable.isEmpty ? .retrying(file) : .done(file)
                if !unrecoverable.isEmpty {
                    alert("Saved with warnings",
                          "\(file.lastPathComponent) was written, but:\n\n"
                            + unrecoverable.map { "• \($0)" }.joined(separator: "\n")
                            + "\n\nDetails in \(Log.file.path)")
                }
            } else {
                let message = result.problems.joined(separator: "\n")
                phase = .failed(message)
                alert("Could not save notes", message + "\n\nDetails in \(Log.file.path)")
            }

            finishTerminationIfPending()
        }
    }

    /// Releases a quit that `applicationShouldTerminate` deferred. Exactly one reply is
    /// allowed, and every terminal exit of `start()` and `stop()` owes it: 0.5.7 replied
    /// only from the end of the pipeline, so Cmd-Q inside the "Starting…" window was never
    /// answered, the app could not be quit at all, and `pendingTermination` went on
    /// swallowing every alert for the rest of the session.
    private func finishTerminationIfPending() {
        guard pendingTermination else { return }
        pendingTermination = false
        Log.write("quit released, nothing left to save")
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// A backfill sweep filled in a note after the fact. Point "Open …" at it and say so
    /// in the menu, but never while something is live: overwriting a recording's status
    /// line would be worse than staying quiet until it finishes.
    func noteBackfilled(_ file: URL) {
        lastNote = file
        switch phase {
        // Says recovered, not merely saved: after a `retrying` status the difference
        // between "the note exists" and "the note finally has its notes" is the whole
        // question the user is left holding.
        case .idle, .done, .retrying, .recovered, .failed: phase = .recovered(file)
        case .recording, .working: break
        }
    }

    /// Every scheduled retry is spent and these notes are still missing their summary.
    /// This is the moment the alert deferred at recording time comes due.
    ///
    /// Keyed off the files rather than the phase. Reading `.retrying` off the phase was
    /// enough to lose the alert entirely: recording a second meeting in the meantime, or
    /// having had an unrecoverable problem alongside the pending summary (which lands in
    /// `.done`, not `.retrying`), left the backfill logging its surrender to nobody.
    func backfillGaveUp(_ files: [URL]) {
        guard let file = files.first else { return }
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        // Never overwrite the status line of something still live, same rule as
        // `noteBackfilled`; the alert still goes out either way.
        switch phase {
        case .recording, .working: break
        default: phase = .failed("no notes for \(names)")
        }
        alert("Could not generate notes",
              "\(names) still \(files.count == 1 ? "has" : "have") no summary after every retry. "
                + "The transcript and audio are safe — run\n\n"
                + "Alpiste --regenerate \(file.path)\n\nto try again.\n\n"
                + "Details in \(Log.file.path)")
    }

    // MARK: - Meeting watcher

    private static let autoStartKey = "AutoStartOnMeetings"

    /// Off until asked for. Auto-starting recordings and reading the calendar are both
    /// things to opt into, not things to discover already happening.
    private(set) var autoStartOnMeetings = UserDefaults.standard.bool(forKey: autoStartKey)

    /// Whether the calendar half of the watcher is usable. Without it the feature still
    /// detects and records calls; it just cannot title them or know when they end, which is
    /// worth saying in the menu rather than only in the log.
    private(set) var meetingCalendarStatus = MeetingCalendar.Access.notAsked

    func setAutoStartOnMeetings(_ enabled: Bool) {
        autoStartOnMeetings = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoStartKey)
        guard enabled else {
            MeetingMonitor.stop()
            return
        }
        MeetingMonitor.start()
        // Asked only now, never at launch: a denial costs the title and the scheduled stop,
        // not the feature itself.
        requestCalendarAccess()
    }

    /// Raises the permission dialog, from the toggle or from the menu item. Safe to call
    /// when it has already been answered: `requestAccess` returns without asking.
    func requestCalendarAccess() {
        Task {
            await MeetingCalendar.requestAccess()
            refreshCalendarStatus()
        }
    }

    /// Polled by the watcher, so granting access in System Settings updates the menu within
    /// a couple of seconds instead of waiting for a relaunch. Assigns only on a change, to
    /// avoid waking the menu's observation on every tick.
    func refreshCalendarStatus() {
        let current = MeetingCalendar.access
        guard current != meetingCalendarStatus else { return }
        meetingCalendarStatus = current
        // Granted in System Settings with the app already running: the store that predates
        // the grant has to be reset, or the menu says available while every lookup is empty.
        if current == .available { MeetingCalendar.accessBecameAvailable() }
        Log.write("meeting calendar: \(MeetingCalendar.statusDescription)")
    }

    /// Resumes watching at launch when the feature was left on.
    func resumeMeetingWatcherIfEnabled() {
        guard autoStartOnMeetings else { return }
        meetingCalendarStatus = MeetingCalendar.access
        Log.write("meeting calendar: \(MeetingCalendar.statusDescription)")
        MeetingMonitor.start()
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
            // Not NSLog: on 2026-08-20 it never reached the unified log, and this is the
            // worst moment to lose a message, since the app is quitting mid-pipeline and
            // the text may well be "Could not save notes". Nothing here is a secret or
            // meeting content, only file names and problem strings.
            Log.write("alert suppressed while quitting: \(title) — \(message)")
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
        Log.startup("launched")
        // Catches notes left unsummarized by an earlier run: the app may well have been
        // quit before its retry schedule had a chance to fire.
        // Showing the panel needs a live app, so this cannot be handled in `init` with the
        // other flags. It is the only way to see the prompt render without waiting for a
        // real call to start.
        if CommandLine.arguments.contains("--prompt-demo") { Self.promptDemo(); return }

        Backfill.sweepAtLaunch()
        Self.recoverOrphanedCaptures()
        AppState.shared.resumeMeetingWatcherIfEnabled()
    }

    /// Captures an earlier run never turned into a note, because it crashed, lost power,
    /// or was force-quit. Nothing used to look at them again: the meeting was lost in
    /// practice while sitting whole on disk, and the directories piled up unseen.
    ///
    /// Safe to run here and only here. Everything in `captures/` at launch predates this
    /// session, so no recording in progress can be swept up by it.
    private static func recoverOrphanedCaptures() {
        let orphans = Recorder.orphanedCaptures()
        guard !orphans.isEmpty else { return }
        Log.write("recovery: \(orphans.count) capture(s) left behind by an earlier run")
        Task {
            for orphan in orphans {
                let result = await Notes.process(orphan.capture, startedAt: orphan.startedAt)
                if let file = result.file {
                    Log.write("recovery: wrote \(file.lastPathComponent)")
                    AppState.shared.noteBackfilled(file)
                } else {
                    Log.write("recovery: could not save "
                                + "\(orphan.capture.directory.lastPathComponent) — "
                                + result.problems.joined(separator: "; "))
                }
            }
        }
    }

    /// `Alpiste --prompt-demo`: shows the meeting prompt and reports which button was
    /// clicked, then exits. Records nothing.
    private static func promptDemo() {
        print("showing the meeting prompt — click a button, or wait for it to time out")
        MeetingPrompt.show(subtitle: "Weekly sync with the design team") {
            print("ok   Record")
            Log.flush()
            exit(0)
        } onDecline: {
            print("ok   Not now")
            Log.flush()
            exit(0)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        switch QuitDecision.decide(isRecording: state.isRecording, isBusy: state.isBusy) {
        case .now:
            return .terminateNow
        case .stopThenWait:
            state.pendingTermination = true
            state.stop()
            return .terminateLater
        case .wait:
            state.pendingTermination = true
            return .terminateLater
        }
    }
}

/// Pure: what Cmd-Q has to do about work in flight. Covered by `--selftest`.
///
/// `.wait` covers the whole of `.working`, which is both the pipeline *and* the
/// "Starting…" window before a stream exists. Both hold the quit, so both oblige
/// `AppState` to answer AppKit once there is nothing left to save.
enum QuitDecision: Equatable {
    /// Nothing in flight: let AppKit tear the app down now.
    case now
    /// A live recording: stop it, then answer once the pipeline has written the note.
    case stopThenWait
    /// Starting up, or saving: answer once that finishes.
    case wait

    static func decide(isRecording: Bool, isBusy: Bool) -> QuitDecision {
        if isRecording { return .stopThenWait }
        return isBusy ? .wait : .now
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
            Log.flush()
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

        // The decoder-loop guard. Thresholds come from measuring every note in
        // ~/MeetingNotes on 2026-08-25: the two ruined transcripts ran 80 and 39 lines
        // deep, the worst healthy one reached 8 ("Bom dia." while a meeting fills up).
        func repeated(_ line: String, _ times: Int, tail: String = "") -> String {
            (Array(repeating: line, count: times) + (tail.isEmpty ? [] : [tail]))
                .joined(separator: "\n")
        }
        expect(Notes.runawayRepetition(repeated("greetings everyone", 8)) == nil,
               "runawayRepetition: a room really repeating itself is not a loop")
        expect(Notes.runawayRepetition(
                   repeated("stuck phrase", Notes.repetitionLimit - 1)) == nil,
               "runawayRepetition: silent just below the limit")
        expect(Notes.runawayRepetition(
                   repeated("stuck phrase", Notes.repetitionLimit)) != nil,
               "runawayRepetition: fires at the limit")
        expect(Notes.runawayRepetition(repeated("stuck phrase", 80)) != nil,
               "runawayRepetition: catches the 45 minute meeting that was lost")
        // Blank lines between segments must not break the run; whisper emits them.
        expect(Notes.runawayRepetition(repeated("stuck phrase\n", 40)) != nil,
               "runawayRepetition: blank lines do not reset the run")
        // Alternating lines are conversation, not a loop, however often they recur.
        let alternating = Array(repeating: "yes\nno", count: 40).joined(separator: "\n")
        expect(Notes.runawayRepetition(alternating) == nil,
               "runawayRepetition: only consecutive repeats count")
        // Problems are echoed to the log, where meeting content must never appear.
        expect(Notes.runawayRepetition(repeated("secret meeting words", 40))?
                .contains("secret") == false,
               "runawayRepetition: never quotes the transcript")

        // -l auto decides from the first 30 seconds and applies that guess to the whole
        // file; a noisy opening turned a Portuguese meeting into an English translation.
        expect(Notes.transcriptionLanguage([:]) == "pt",
               "transcriptionLanguage: pinned by default, never auto")
        expect(Notes.transcriptionLanguage(["WHISPER_LANGUAGE": "en"]) == "en",
               "transcriptionLanguage: honours the override")
        expect(Notes.transcriptionLanguage(["WHISPER_LANGUAGE": "  "]) == "pt",
               "transcriptionLanguage: a blank override falls back rather than breaking the call")

        // What --retranscribe needs to find the recording again.
        expect(Notes.audioFileName(inNote: full) == "2026-07-31-2214.m4a",
               "audioFileName: reads the audio line markdown() writes")
        expect(Notes.audioFileName(inNote: oneSource) == "a.m4a",
               "audioFileName: ignores the trailing sources")
        expect(Notes.audioFileName(inNote: "# title only") == nil,
               "audioFileName: nil when the note names no audio")
        // A note whose transcription failed outright has no divider, and that is exactly
        // the note --retranscribe exists for, so the header must still come back.
        expect(Notes.noteHeader(noTranscript)?.contains("a.m4a") == true,
               "noteHeader: works on a note with no usable transcript")
        expect(Notes.noteHeader("no title line") == nil,
               "noteHeader: nil without a title")

        // Provider order is a deliberate call, not an accident of how the ifs are typed:
        // Gemini's free tier caps at 20 requests a day and lost three meetings in two
        // days, while Groq answered every time it was asked. Groq leads.
        let bothKeys = ["GROQ_API_KEY": "g", "GEMINI_API_KEY": "x"]
        let short = 5_000
        // The transcript that hit Groq's 413 on 2026-08-20: 38772 characters, which the
        // API counted as 9475 tokens against an 8000-per-minute cap.
        let long = 38_772

        expect(Notes.summaryProviders(bothKeys, transcriptCharacters: short) == [.groq, .gemini],
               "summaryProviders: Groq leads on a short transcript")
        expect(Notes.summaryProviders(bothKeys, transcriptCharacters: long) == [.gemini, .groq],
               "summaryProviders: Gemini leads on a transcript too long for Groq")
        // Reordering, not dropping: on 2026-08-20 Gemini answered 503 four times running,
        // and a list with one provider left in it would have had nowhere to fall through to.
        expect(Notes.summaryProviders(bothKeys, transcriptCharacters: long).count == 2,
               "summaryProviders: the long-transcript order keeps Groq as the fallback")
        expect(Notes.summaryProviders(bothKeys, transcriptCharacters: Notes.groqTranscriptLimit)
                == [.groq, .gemini],
               "summaryProviders: the limit itself still leads with Groq")
        expect(Notes.summaryProviders(bothKeys, transcriptCharacters: Notes.groqTranscriptLimit + 1)
                == [.gemini, .groq],
               "summaryProviders: one character past the limit flips the order")
        expect(Notes.summaryProviders(["GEMINI_API_KEY": "x"], transcriptCharacters: short) == [.gemini],
               "summaryProviders: Gemini alone when Groq has no key")
        expect(Notes.summaryProviders(["GROQ_API_KEY": "g"], transcriptCharacters: short) == [.groq],
               "summaryProviders: Groq alone when Gemini has no key")
        expect(Notes.summaryProviders(["GROQ_API_KEY": "g"], transcriptCharacters: long) == [.groq],
               "summaryProviders: a long transcript still tries Groq when it is the only key")
        expect(Notes.summaryProviders(["GEMINI_API_KEY": "", "GROQ_API_KEY": ""],
                                      transcriptCharacters: short).isEmpty,
               "summaryProviders: an empty key does not count as configured")

        // The alert path keys off this prefix to tell a failure the backfill will retry
        // from one it cannot. If the two drift apart, every summary failure goes back to
        // firing a modal that the retry schedule immediately contradicts.
        expect(Notes.markdown(title: "t", notes: nil, transcript: "x", audioFile: nil,
                              problems: [Notes.summaryFailurePrefix + "Groq: 413"])
                .contains(Notes.noNotesPlaceholder),
               "summaryFailurePrefix: a summary failure leaves the note pending")

        let summaryFailed = Notes.summaryFailurePrefix + "Groq: 413 / Gemini: 503"
        let mixFailed = "Audio mixing failed: ffmpeg exited 1"
        expect(Notes.problemsWorthAlerting([summaryFailed], summaryPending: true).isEmpty,
               "problemsWorthAlerting: a retryable summary failure raises no alert")
        expect(Notes.problemsWorthAlerting([summaryFailed, mixFailed], summaryPending: true)
                == [mixFailed],
               "problemsWorthAlerting: a mix failure still alerts alongside a retryable one")
        // Nothing is going to retry it, so withholding it would bury the failure entirely.
        expect(Notes.problemsWorthAlerting([summaryFailed], summaryPending: false) == [summaryFailed],
               "problemsWorthAlerting: a summary failure nobody will retry does alert")
        expect(Notes.problemsWorthAlerting([], summaryPending: true).isEmpty,
               "problemsWorthAlerting: a clean run raises nothing")

        expect(Notes.stamp(Date(timeIntervalSince1970: 0)).count == 15, "stamp: YYYY-MM-DD-HHMM")
        // Guards against a non-Gregorian system calendar (Japanese, Buddhist, ...)
        // silently turning "yyyy" into an era year and breaking the filename format.
        expect(Notes.stamp(Date(timeIntervalSince1970: 0)).allSatisfy { "0123456789-".contains($0) },
               "stamp: digits and dashes regardless of system calendar")

        expect(Notes.uniqueStem("x") { $0 == "x" || $0 == "x-2" } == "x-3",
               "uniqueStem: skips names that are already taken")
        expect(Notes.uniqueStem("y") { _ in false } == "y",
               "uniqueStem: keeps an untaken name as-is")

        // The meeting watcher's classifier. The process CoreAudio reports is a helper, not
        // the app, so these must match by prefix; measured 2026-08-24 with Comet in a call
        // showing up as ai.perplexity.comet.helper.
        expect(MeetingWatcher.classify(bundleID: "com.google.Chrome.helper") == .meeting,
               "classify: a browser helper counts as its parent browser")
        expect(MeetingWatcher.classify(bundleID: "ai.perplexity.comet.helper") == .meeting,
               "classify: the helper name CoreAudio actually reported")
        expect(MeetingWatcher.classify(bundleID: "com.google.chrome") == .meeting,
               "classify: bundle IDs match case-insensitively")
        expect(MeetingWatcher.classify(bundleID: "com.google.ChromeOther") == .unknown,
               "classify: a prefix only matches on a component boundary")
        expect(MeetingWatcher.classify(bundleID: "com.apple.Music") == .unknown,
               "classify: an unrelated app is unknown, not a meeting")
        // The two that make the feature usable instead of a prompt every few minutes.
        expect(MeetingWatcher.classify(bundleID: "com.electron.wispr-flow") == .ignored,
               "classify: Wispr Flow dictation never counts as a meeting")
        expect(MeetingWatcher.classify(bundleID: "com.sparrow.alpiste") == .ignored,
               "classify: Alpiste's own capture never counts as a meeting")
        expect(MeetingWatcher.classify(bundleID: "com.electron.wispr-flow",
                                       meetingApps: ["com.electron.wispr-flow"]) == .ignored,
               "classify: the deny list wins over configuration")

        // A boolean here is what sent the user to a Settings pane that did not list the app.
        expect(MeetingCalendar.access(for: .fullAccess) == .available,
               "calendar access: full access is usable")
        expect(MeetingCalendar.access(for: .notDetermined) == .notAsked,
               "calendar access: never answered means the dialog still works")
        expect(MeetingCalendar.access(for: .denied) == .blocked,
               "calendar access: a refusal only System Settings can undo")
        expect(MeetingCalendar.access(for: .restricted) == .blocked,
               "calendar access: restricted by policy is blocked, not askable")
        expect(MeetingCalendar.access(for: .writeOnly) == .blocked,
               "calendar access: write-only cannot read events and will not be upgraded")

        let joined = Date(timeIntervalSince1970: 1_000_000)
        expect(!MeetingWatcher.shouldPrompt(activeSince: nil, now: joined, suppressed: false),
               "shouldPrompt: nothing on the microphone raises nothing")
        expect(!MeetingWatcher.shouldPrompt(activeSince: joined,
                                            now: joined.addingTimeInterval(19),
                                            suppressed: false),
               "shouldPrompt: silent until the debounce has elapsed")
        expect(MeetingWatcher.shouldPrompt(activeSince: joined,
                                           now: joined.addingTimeInterval(20),
                                           suppressed: false),
               "shouldPrompt: fires once the microphone has been held long enough")
        expect(!MeetingWatcher.shouldPrompt(activeSince: joined,
                                            now: joined.addingTimeInterval(600),
                                            suppressed: true),
               "shouldPrompt: Not now, or an existing recording, keeps it quiet")

        let onMic = [MeetingWatcher.AudioProcess(bundleID: "com.electron.wispr-flow",
                                                 isRunningInput: true),
                     MeetingWatcher.AudioProcess(bundleID: "com.apple.Music",
                                                 isRunningInput: false),
                     MeetingWatcher.AudioProcess(bundleID: "com.google.Chrome.helper",
                                                 isRunningInput: true)]
        expect(MeetingWatcher.meetingAppOnMicrophone(onMic) == "com.google.Chrome.helper",
               "meetingAppOnMicrophone: finds the browser past a dictating Wispr Flow")
        expect(MeetingWatcher.meetingAppOnMicrophone(
                   [MeetingWatcher.AudioProcess(bundleID: "com.google.Chrome.helper",
                                                isRunningInput: false)]) == nil,
               "meetingAppOnMicrophone: playing audio is not holding the microphone")

        func event(_ title: String, _ startOffset: TimeInterval, _ endOffset: TimeInterval,
                   allDay: Bool = false, details: String = "", attendees: Int = 0,
                   canceled: Bool = false, declined: Bool = false)
            -> MeetingWatcher.CalendarEvent {
            MeetingWatcher.CalendarEvent(title: title,
                                         start: joined.addingTimeInterval(startOffset),
                                         end: joined.addingTimeInterval(endOffset),
                                         isAllDay: allDay, details: details,
                                         attendeeCount: attendees,
                                         isCanceled: canceled, isDeclined: declined)
        }
        expect(MeetingWatcher.looksLikeMeeting(
                   event("x", -60, 600, details: "https://meet.google.com/abc-defg-hij")),
               "looksLikeMeeting: a conference link is enough")
        expect(MeetingWatcher.looksLikeMeeting(event("x", -60, 600, attendees: 3)),
               "looksLikeMeeting: several attendees are enough without a link")
        expect(!MeetingWatcher.looksLikeMeeting(event("x", -60, 600, attendees: 1)),
               "looksLikeMeeting: a solo reminder is not a meeting")
        expect(!MeetingWatcher.looksLikeMeeting(
                   event("x", -60, 600, allDay: true, details: "zoom.us/j/1")),
               "looksLikeMeeting: an all-day entry is never the call you just joined")
        // Both of these keep their conference link and their attendees, and meetingEvent
        // takes the latest start, so a stale 10:00 all-hands outranks the ad-hoc call at
        // 10:05 and names the note after the wrong meeting, with the wrong end time.
        expect(!MeetingWatcher.looksLikeMeeting(
                   event("x", -60, 600, attendees: 5, canceled: true)),
               "looksLikeMeeting: an event the organiser cancelled is not a meeting")
        expect(!MeetingWatcher.looksLikeMeeting(
                   event("x", -60, 600, attendees: 5, declined: true)),
               "looksLikeMeeting: an event you declined is not the call you just joined")
        expect(MeetingWatcher.meetingEvent(
                   [event("declined all-hands", -300, 1800, attendees: 40, declined: true),
                    event("the call you joined", -60, 1800, attendees: 2)],
                   at: joined)?.title == "the call you joined",
               "meetingEvent: a declined event does not outrank the real call")

        let overlapping = [event("earlier", -3600, 3600, attendees: 2),
                           event("just started", -120, 1800, attendees: 2),
                           event("later", 1800, 3600, attendees: 2)]
        expect(MeetingWatcher.meetingEvent(overlapping, at: joined)?.title == "just started",
               "meetingEvent: overlapping events resolve to the one just joined")
        expect(MeetingWatcher.meetingEvent([event("done", -7200, -3600, attendees: 2)],
                                           at: joined) == nil,
               "meetingEvent: an event that already ended does not match")

        // Joining a call in its last minutes must still produce a usable recording.
        expect(MeetingWatcher.autoStopDate(eventEnd: joined.addingTimeInterval(1800),
                                           startedAt: joined)
                == joined.addingTimeInterval(1800 + 300),
               "autoStopDate: the calendar end plus a grace period")
        expect(MeetingWatcher.autoStopDate(eventEnd: joined.addingTimeInterval(60),
                                           startedAt: joined)
                == joined.addingTimeInterval(600),
               "autoStopDate: never stops before the minimum recording length")

        // Cmd-Q while something is in flight. `.wait` is the case that was broken: the
        // "Starting…" window is `.working` with no session yet, AppKit was told to hold
        // the quit, and nothing ever answered it, so the app could not be quit at all.
        expect(QuitDecision.decide(isRecording: false, isBusy: false) == .now,
               "quit: an idle app quits immediately")
        expect(QuitDecision.decide(isRecording: true, isBusy: false) == .stopThenWait,
               "quit: a live recording is stopped and saved first")
        expect(QuitDecision.decide(isRecording: false, isBusy: true) == .wait,
               "quit: starting up or saving holds the quit until it is answered")

        // `Alpiste --regenerate --backfill` used to go looking for a file named
        // "--backfill" and fail with an error about the wrong thing entirely.
        expect(AlpisteApp.operand(after: "--regenerate",
                                  in: ["Alpiste", "--regenerate", "note.md"]) == "note.md",
               "operand: reads the path after the flag")
        expect(AlpisteApp.operand(after: "--regenerate",
                                  in: ["Alpiste", "--regenerate", "--backfill"]) == nil,
               "operand: another flag is not a path")
        expect(AlpisteApp.operand(after: "--regenerate", in: ["Alpiste", "--regenerate"]) == nil,
               "operand: nil when the flag ends the line")

        // A capture daemon that never answers must not park the app in "Starting…"
        // forever, so the ceiling abandons the call rather than waiting it out.
        let ceiling = Date()
        do {
            _ = try await Recorder.withDeadline(1, "selftest") {
                try await Task.sleep(for: .seconds(30))
                return 0
            }
            expect(false, "withDeadline: abandons work that outruns the ceiling")
        } catch {
            expect(Date().timeIntervalSince(ceiling) < 10,
                   "withDeadline: abandons work that outruns the ceiling")
        }
        let landed = try? await Recorder.withDeadline(30, "selftest") { 7 }
        expect(landed == 7, "withDeadline: a result that arrives in time comes straight back")

        // Back-to-back meetings, the most ordinary calendar there is. A boolean "already
        // offered" stayed true from the first call through the second, because the
        // microphone never went idle while whisper was still working on the first, and the
        // second meeting was never offered and never logged.
        let firstCall = joined
        let secondCall = joined.addingTimeInterval(3600)
        expect(MeetingWatcher.alreadyOffered(session: firstCall, offered: firstCall),
               "alreadyOffered: the call already answered stays quiet")
        expect(!MeetingWatcher.alreadyOffered(session: secondCall, offered: firstCall),
               "alreadyOffered: the meeting that follows is a new session and is offered")
        expect(!MeetingWatcher.alreadyOffered(session: firstCall, offered: nil),
               "alreadyOffered: nothing answered yet")
        expect(!MeetingWatcher.alreadyOffered(session: nil, offered: firstCall),
               "alreadyOffered: no session on the microphone is never suppressed")

        // "Never seen active" read as "idle forever" stopped a live recording the moment
        // the toggle was switched back on mid-call.
        expect(MeetingWatcher.idleInterval(since: nil, now: joined) == 0,
               "idleInterval: a microphone never seen active does not count as idle")
        expect(MeetingWatcher.idleInterval(since: joined,
                                           now: joined.addingTimeInterval(90)) == 90,
               "idleInterval: measured from the last activity")

        // The forgotten meeting tab: the browser holds the microphone, every tick hands
        // out another block, and the capture outruns whisper's own four-hour ceiling.
        expect(!MeetingWatcher.exceededMaximum(startedAt: joined,
                                               now: joined.addingTimeInterval(3600),
                                               maximum: 4 * 3600),
               "exceededMaximum: a long meeting still runs")
        expect(MeetingWatcher.exceededMaximum(startedAt: joined,
                                              now: joined.addingTimeInterval(4 * 3600),
                                              maximum: 4 * 3600),
               "exceededMaximum: the ceiling stops a recording nothing else would")
        expect(!MeetingWatcher.exceededMaximum(startedAt: nil, now: joined, maximum: 1),
               "exceededMaximum: a recording the watcher did not start has no ceiling")

        // The rescue is the last line before a recording is gone for good, and what it
        // could *not* move is the half that matters: reporting only the successes let the
        // caller delete the capture directory anyway, which destroyed the other track on a
        // partial move and, on a total failure, deleted the very folder the note had just
        // told the user the audio was left in.
        let rescueRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpiste-selftest-rescue-\(UUID().uuidString)")
        func rescueCase(_ name: String, mic: Bool, blocked: Bool) -> Notes.Rescue {
            let from = rescueRoot.appendingPathComponent("\(name)-capture")
            let to = rescueRoot.appendingPathComponent("\(name)-notes")
            for directory in [from, to] {
                try? FileManager.default.createDirectory(at: directory,
                                                         withIntermediateDirectories: true)
            }
            func write(_ url: URL) -> URL {
                FileManager.default.createFile(atPath: url.path, contents: Data([0, 1, 2, 3]))
                return url
            }
            let system = write(from.appendingPathComponent("system.caf"))
            let microphone = mic ? write(from.appendingPathComponent("mic.caf")) : nil
            // An existing destination is what a move actually fails on, and a colliding
            // rescued file from an earlier failure is the realistic way to get one.
            if blocked { _ = write(to.appendingPathComponent("\(name)-mic.caf")) }
            return Notes.rescueRawAudio(Recorder.Capture(directory: from,
                                                         systemAudio: system,
                                                         microphone: microphone),
                                        stem: name, to: to)
        }
        let bothMoved = rescueCase("full", mic: true, blocked: false)
        expect(bothMoved.complete, "rescueRawAudio: both tracks moved, the capture may go")
        expect(bothMoved.audioFile == "full-system.caf",
               "rescueRawAudio: names the rescued file so --retranscribe can find it")
        let partial = rescueCase("partial", mic: true, blocked: true)
        expect(!partial.complete,
               "rescueRawAudio: a track that could not be moved keeps the capture alive")
        expect(partial.problems.contains { $0.contains("mic.caf") },
               "rescueRawAudio: says which file was left behind")
        let systemOnly = rescueCase("solo", mic: false, blocked: false)
        expect(systemOnly.complete && systemOnly.audioFile == "solo-system.caf",
               "rescueRawAudio: an absent microphone is not a failure to move it")
        try? FileManager.default.removeItem(at: rescueRoot)

        // whisper-cli's -np means "print nothing but the results", and the results are the
        // transcript. Tool.run puts the tail of that log into the error message, which is
        // echoed to alpiste.log and shown in an alert.
        let runRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpiste-selftest-run-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
        let echo = URL(fileURLWithPath: "/bin/echo")
        try? await Tool.run(echo, ["what was said in the meeting"], in: runRoot, label: "kept")
        try? await Tool.run(echo, ["what was said in the meeting"], in: runRoot,
                            label: "dropped", discardStandardOutput: true)
        func logged(_ label: String) -> String {
            (try? String(contentsOf: runRoot.appendingPathComponent("\(label).log"),
                         encoding: .utf8)) ?? ""
        }
        expect(logged("kept").contains("what was said"),
               "Tool.run: stdout reaches the command log by default")
        expect(!logged("dropped").contains("what was said"),
               "Tool.run: discardStandardOutput keeps the transcript out of the log")
        try? FileManager.default.removeItem(at: runRoot)

        // Regeneration rebuilds the file by hand instead of through markdown(); if the two
        // compositions drift, the backfill stops recognising the notes it just wrote.
        if let parts = Notes.split(markdown: failed) {
            let regenerated = parts.header + "\n\n## Summary\n- p\n"
                + Notes.transcriptDivider + parts.transcript + "\n"
            expect(Notes.split(markdown: regenerated)?.transcript == "raw text",
                   "regenerate: the rebuilt note still parses")
            expect(!Notes.pendingSummary(markdown: regenerated),
                   "regenerate: the rebuilt note stops reading as pending")
        }

        // A capture the app never turned into a note is the last place a recording can
        // hide, and --retranscribe keeps its scratch space in the same folder: sweeping
        // that up would re-process a note already on disk.
        let captures = FileManager.default.temporaryDirectory
            .appendingPathComponent("alpiste-selftest-captures-\(UUID().uuidString)")
        func makeCapture(_ name: String, bytes: Int) -> URL {
            let directory = captures.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: directory.appendingPathComponent("system.caf").path,
                                           contents: Data(repeating: 0, count: bytes))
            return directory
        }
        let stranded = makeCapture("alpiste-stranded", bytes: 1024)
        let empty = makeCapture("alpiste-empty", bytes: 0)
        let scratch = makeCapture("retranscribe-scratch", bytes: 1024)
        let orphans = Recorder.orphanedCaptures(in: captures)
        expect(orphans.count == 1 && orphans.first?.capture.directory.lastPathComponent
                == stranded.lastPathComponent,
               "orphanedCaptures: finds the capture an interrupted run left behind")
        expect(!FileManager.default.fileExists(atPath: empty.path),
               "orphanedCaptures: clears a directory that never received audio")
        expect(FileManager.default.fileExists(atPath: scratch.path),
               "orphanedCaptures: leaves the --retranscribe scratch space alone")
        try? FileManager.default.removeItem(at: captures)

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
        // A log that silently fails to write would put us back where 2026-08-20 left us,
        // so prove it round-trips rather than assuming the directory is there.
        let marker = "selftest marker \(UUID().uuidString)"
        Log.write(marker)
        let logged = (try? String(contentsOf: Log.flushed(), encoding: .utf8)) ?? ""
        expect(logged.contains(marker), "log: writes reach \(Log.file.path)")

        let whisper = Tool.find("whisper-cli") != nil
        print("\(whisper ? "ok  " : "note") tools: whisper-cli \(whisper ? "found" : "missing, run scripts/setup.sh")")
        let model = FileManager.default.fileExists(atPath: Notes.modelURL.path)
        print("\(model ? "ok  " : "note") model: ggml-medium.bin \(model ? "present" : "missing, run scripts/setup.sh")")

        return failures
    }
}
