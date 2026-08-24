import CoreAudio
import Foundation

/// Notices that a call has started and asks whether to record it.
///
/// The trigger is audio, not the calendar: an event you never joined must not prompt, and a
/// call that was never scheduled must still be caught. CoreAudio has exposed per-process
/// audio activity since macOS 14.4 (`kAudioHardwarePropertyProcessObjectList`), which answers
/// "is a meeting app holding the microphone right now" without any extra permission.
///
/// The calendar is context, not trigger: once audio has fired, a matching event supplies the
/// note's title and the time to stop.
///
/// Two entries on the deny list are load-bearing rather than cosmetic. Wispr Flow holds the
/// microphone all day for dictation and would otherwise prompt constantly, and Alpiste itself
/// holds the microphone while recording, which would make the watcher feed on its own capture.
enum MeetingWatcher {
    // MARK: - Classification

    enum Source: Equatable {
        /// An app whose microphone use means a call is probably underway.
        case meeting
        /// Known to hold the microphone for something that is not a call.
        case ignored
        case unknown
    }

    /// Bundle ID prefixes, not whole identifiers: the process that actually holds the device
    /// is a helper, not the app. Measured on 2026-08-24 — Comet in a call shows up as
    /// `ai.perplexity.comet.helper`, and Chrome's renderer is `com.google.Chrome.helper`.
    /// Matching the parent exactly would find neither.
    static let defaultMeetingApps = [
        "com.google.Chrome",
        "com.apple.Safari",
        "ai.perplexity.comet",
        "company.thebrowser.Browser",   // Arc
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "org.ferdium.ferdium-app",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.FaceTime",
    ]

    /// Never overridable from configuration: allowing either of these through is not a
    /// preference, it is a bug that shows up as a prompt every few minutes.
    static let alwaysIgnoredApps = [
        "com.electron.wispr-flow",
        "com.sparrow.alpiste",
    ]

    /// Pure. Covered by `--selftest`.
    static func classify(bundleID: String, meetingApps: [String] = defaultMeetingApps) -> Source {
        func matches(_ prefixes: [String]) -> Bool {
            let id = bundleID.lowercased()
            return prefixes.contains { prefix in
                let prefix = prefix.lowercased()
                // The trailing dot keeps `com.google.Chrome` from claiming a hypothetical
                // `com.google.ChromeSomethingElse`.
                return id == prefix || id.hasPrefix(prefix + ".")
            }
        }
        if matches(alwaysIgnoredApps) { return .ignored }
        if matches(meetingApps) { return .meeting }
        return .unknown
    }

    // MARK: - Prompting

    static let defaultDebounce: TimeInterval = 20
    static let defaultStopGrace: TimeInterval = 5 * 60
    /// A call joined in its last minutes still deserves a usable recording, so the auto-stop
    /// never lands sooner than this after the recording started.
    static let minimumRecording: TimeInterval = 10 * 60

    /// Pure. Covered by `--selftest`.
    ///
    /// `activeSince` is when a meeting app first took the microphone and has held it since;
    /// nil means nothing is holding it. `suppressed` covers both "the user said Not now for
    /// this call" and "a recording is already underway".
    static func shouldPrompt(activeSince: Date?,
                             now: Date,
                             debounce: TimeInterval = defaultDebounce,
                             suppressed: Bool) -> Bool {
        guard !suppressed, let activeSince else { return false }
        return now.timeIntervalSince(activeSince) >= debounce
    }

    // MARK: - Calendar matching

    /// The fields this file needs from an `EKEvent`, so the matching logic stays pure and
    /// testable without a calendar permission or a live event store.
    struct CalendarEvent: Equatable {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        /// url, location and notes concatenated: a conference link hides in a different one
        /// of these depending on who sent the invite.
        let details: String
        let attendeeCount: Int
    }

    static let conferenceHosts = [
        "meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "chime.aws", "bluejeans.com",
        "gotomeeting.com", "around.co", "riverside.fm", "discord.gg",
    ]

    /// Pure. Covered by `--selftest`.
    static func looksLikeMeeting(_ event: CalendarEvent) -> Bool {
        if event.isAllDay { return false }
        let details = event.details.lowercased()
        if conferenceHosts.contains(where: details.contains) { return true }
        // No link, but more than one person: a scheduled conversation either way.
        return event.attendeeCount > 1
    }

    /// Pure. Covered by `--selftest`. Picks the event that is running right now; when several
    /// overlap, the one that started most recently, which is the one just joined.
    static func meetingEvent(_ events: [CalendarEvent], at now: Date) -> CalendarEvent? {
        events
            .filter { $0.start <= now && now < $0.end && looksLikeMeeting($0) }
            .max { $0.start < $1.start }
    }

    /// Pure. Covered by `--selftest`. When the calendar knows the end, stop a little after it
    /// so an overrun is not cut off, but never before `minimumRecording` has elapsed.
    static func autoStopDate(eventEnd: Date,
                             startedAt: Date,
                             grace: TimeInterval = defaultStopGrace,
                             minimum: TimeInterval = minimumRecording) -> Date {
        max(eventEnd.addingTimeInterval(grace), startedAt.addingTimeInterval(minimum))
    }

    // MARK: - Reading CoreAudio

    /// One process with live audio, as CoreAudio reports it.
    struct AudioProcess: Equatable {
        let bundleID: String
        let isRunningInput: Bool
    }

    /// Every process CoreAudio currently accounts for. Cheap enough to poll: the whole call
    /// is a couple of property reads per process, with no allocation of note.
    static func audioProcesses() -> [AudioProcess] {
        var addr = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var objects = [AudioObjectID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects.compactMap { object in
            guard let bundleID = stringProperty(object, kAudioProcessPropertyBundleID) else {
                return nil
            }
            let input = (numberProperty(object, kAudioProcessPropertyIsRunningInput) ?? 0) != 0
            return AudioProcess(bundleID: bundleID, isRunningInput: input)
        }
    }

    /// Pure. Covered by `--selftest`. The bundle ID of a meeting app currently on the
    /// microphone, or nil. Names the app so the log can say what triggered the prompt.
    static func meetingAppOnMicrophone(_ processes: [AudioProcess],
                                       meetingApps: [String] = defaultMeetingApps) -> String? {
        processes
            .filter { $0.isRunningInput }
            .first { classify(bundleID: $0.bundleID, meetingApps: meetingApps) == .meeting }?
            .bundleID
    }

    private static func propertyAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(_ object: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = propertyAddress(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func numberProperty(_ object: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> UInt32? {
        var addr = propertyAddress(selector)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        return AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr
            ? value : nil
    }
}

/// Runs the watcher: polls CoreAudio, raises the prompt, and stops the recording when the
/// call is over. Split from `MeetingWatcher` so that everything above stays pure and
/// testable while the timers and side effects live in one place, the way `Backfill` does.
@MainActor
enum MeetingMonitor {
    /// Two seconds is imperceptible next to the 20-second debounce and costs a couple of
    /// property reads. A CoreAudio property listener was the alternative, but per-process
    /// `IsRunningInput` does not notify reliably, so polling is the honest mechanism.
    private static let pollInterval: TimeInterval = 2
    /// A renderer restarting mid-call drops the microphone for a moment. Waiting this long
    /// before declaring the call over keeps a blip from re-arming the prompt.
    private static let callEndGrace: TimeInterval = 15
    /// Backstop when no calendar event bounds the recording.
    private static let idleStopWithoutEvent: TimeInterval = 5 * 60
    /// With a calendar end in hand the recording is already bounded, so this only exists to
    /// avoid taping an hour of silence after leaving early. Deliberately generous: a long
    /// stretch on mute must never cut a meeting that is still running.
    private static let idleStopWithEvent: TimeInterval = 15 * 60

    private static var ticker: Timer?
    private static var micActiveSince: Date?
    private static var lastMicActivity: Date?
    /// The call underway has already been offered, whether it was accepted, declined or
    /// timed out. Not merely "declined": a recording that fails to start would otherwise
    /// leave the call live with nothing suppressing the panel, and it would reappear on
    /// every tick.
    private static var offered = false
    private static var startedByWatcher = false
    private static var autoStopAt: Date?

    static func start() {
        guard ticker == nil else { return }
        Log.write("meeting watcher: watching for calls")
        let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor in tick(now: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    static func stop() {
        ticker?.invalidate()
        ticker = nil
        MeetingPrompt.dismiss()
        micActiveSince = nil
        lastMicActivity = nil
        offered = false
        Log.write("meeting watcher: stopped watching")
    }

    static var isWatching: Bool { ticker != nil }

    private static func tick(now: Date) {
        let onMic = MeetingWatcher.meetingAppOnMicrophone(MeetingWatcher.audioProcesses(),
                                                          meetingApps: Settings.meetingApps)
        if let app = onMic {
            if micActiveSince == nil {
                micActiveSince = now
                Log.write("meeting watcher: \(app) took the microphone")
            }
            lastMicActivity = now
        }
        let idleFor = lastMicActivity.map { now.timeIntervalSince($0) } ?? .infinity

        let state = AppState.shared
        // Cheap, and it means granting access in System Settings is reflected in the menu
        // within a tick instead of at the next launch.
        state.refreshCalendarStatus()
        if state.isRecording {
            // Recording started from the menu while the panel was still up: the question
            // has been answered, so take it off the screen.
            if MeetingPrompt.isShowing { MeetingPrompt.dismiss() }
            if startedByWatcher { considerAutoStop(now: now, idleFor: idleFor) }
            return
        }
        // A recording this watcher started has ended, by auto-stop or by hand; either way
        // its schedule is spent.
        if startedByWatcher, !state.isBusy { clearRecordingState() }
        guard !state.isBusy else { return }

        // The call is over: re-arm, so the next meeting is offered again.
        if idleFor >= callEndGrace {
            // A panel still up is now offering to record a call that has already ended,
            // and clicking Record would capture the silence after it.
            if MeetingPrompt.isShowing {
                Log.write("meeting watcher: the call ended before the prompt was answered")
                MeetingPrompt.dismiss()
            }
            micActiveSince = nil
            offered = false
        }

        guard MeetingWatcher.shouldPrompt(activeSince: micActiveSince,
                                          now: now,
                                          debounce: Settings.debounce,
                                          suppressed: offered)
        else { return }
        offer(now: now)
    }

    private static func offer(now: Date) {
        offered = true
        let event = MeetingCalendar.currentMeeting(at: now)
        // The title is meeting content and never reaches the log; whether one was matched
        // is a decision, and that does.
        Log.write("meeting watcher: prompting (calendar event "
                    + (event == nil ? "not matched)" : "matched)"))

        MeetingPrompt.show(subtitle: event?.title) {
            // Date() rather than the captured `now`: the panel may have sat on screen for
            // a minute and a half, and the auto-stop floor is measured from the recording.
            accept(event: event, now: Date())
        } onDecline: {
            Log.write("meeting watcher: declined, staying quiet until this call ends")
        }
    }

    private static func accept(event: MeetingWatcher.CalendarEvent?, now: Date) {
        startedByWatcher = true
        if let event {
            let stopAt = MeetingWatcher.autoStopDate(eventEnd: event.end,
                                                    startedAt: now,
                                                    grace: Settings.stopGrace)
            autoStopAt = stopAt
            Log.write("meeting watcher: recording, auto-stop in "
                        + "\(Int(stopAt.timeIntervalSince(now) / 60))m")
        } else {
            autoStopAt = nil
            Log.write("meeting watcher: recording, no calendar event — "
                        + "will stop once the microphone goes idle")
        }
        AppState.shared.start(title: event?.title)
    }

    private static func considerAutoStop(now: Date, idleFor: TimeInterval) {
        let idleLimit = autoStopAt == nil ? idleStopWithoutEvent : idleStopWithEvent
        if idleFor >= idleLimit {
            Log.write("meeting watcher: microphone idle for "
                        + "\(Int(idleFor / 60))m, stopping the recording")
            finish()
            return
        }
        // Past the calendar end but the call is still live: the meeting ran over, so give
        // it another block rather than cutting it off mid-sentence.
        guard let stopAt = autoStopAt, now >= stopAt else { return }
        if idleFor < callEndGrace {
            autoStopAt = stopAt.addingTimeInterval(Settings.overrunExtension)
            Log.write("meeting watcher: past the calendar end but the call is still live, "
                        + "extending by \(Int(Settings.overrunExtension / 60))m")
            return
        }
        Log.write("meeting watcher: calendar end reached, stopping the recording")
        finish()
    }

    private static func finish() {
        clearRecordingState()
        AppState.shared.stop()
    }

    private static func clearRecordingState() {
        startedByWatcher = false
        autoStopAt = nil
    }

    /// Tunables, read from `~/.alpiste/.env` at each use so a change takes effect without a
    /// relaunch. Defaults are the ones the pure functions document.
    @MainActor
    enum Settings {
        static var debounce: TimeInterval {
            seconds("MEETING_DEBOUNCE_SECONDS") ?? MeetingWatcher.defaultDebounce
        }
        static var stopGrace: TimeInterval {
            minutes("MEETING_STOP_GRACE_MINUTES") ?? MeetingWatcher.defaultStopGrace
        }
        static var overrunExtension: TimeInterval {
            minutes("MEETING_OVERRUN_MINUTES") ?? 10 * 60
        }
        /// Extra bundle ID prefixes, comma separated. Never able to re-enable a denied app.
        static var meetingApps: [String] {
            let extra = (env()["MEETING_APPS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return MeetingWatcher.defaultMeetingApps + extra
        }

        /// The poll runs every two seconds and reads several of these, so the file is not
        /// re-read every time. The cache still expires, which keeps the promise that an
        /// edit takes effect without relaunching the app.
        private static let cacheLifetime: TimeInterval = 30
        private static var cached: [String: String] = [:]
        private static var cachedAt: Date?

        static func env() -> [String: String] {
            if let cachedAt, Date().timeIntervalSince(cachedAt) < cacheLifetime { return cached }
            cached = Env.load()
            cachedAt = Date()
            return cached
        }

        private static func seconds(_ key: String) -> TimeInterval? {
            env()[key].flatMap(Double.init)
        }
        private static func minutes(_ key: String) -> TimeInterval? {
            env()[key].flatMap(Double.init).map { $0 * 60 }
        }
    }
}
