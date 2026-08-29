import AppKit
import EventKit
import Foundation

/// The calendar half of the meeting watcher: the title of the call you just joined and the
/// time it is supposed to end.
///
/// Strictly context, never a trigger. Nothing here can start a recording; it only answers a
/// question the audio watcher has already asked. That is why every failure path degrades to
/// nil instead of surfacing an error: no permission, no accounts, or no matching event all
/// mean the same thing to the caller, which is "record it without a title and stop when the
/// microphone goes quiet".
///
/// Access is requested lazily, the first time the feature is switched on, never at launch: an
/// app that asks for the calendar the moment it opens, for a feature the user has not turned
/// on, has earned the Don't Allow it gets.
@MainActor
enum MeetingCalendar {
    private static let store = EventStore()

    /// Three states, because a boolean cannot tell the two failures apart and they need
    /// opposite actions from the user: one is answered by a dialog this app can raise, the
    /// other only by System Settings. Collapsing them is what produced a menu item that
    /// sent the user to a pane where Alpiste was not even listed.
    enum Access: Equatable {
        case available
        /// The dialog has never been answered, so asking again still works.
        case notAsked
        /// Refused or forbidden. macOS will not ask again; only System Settings can undo it.
        case blocked
    }

    /// Pure, and deliberately `nonisolated`: it touches nothing shared, and `--selftest`
    /// calls it from off the main actor.
    nonisolated static func access(for status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess: .available
        case .notDetermined: .notAsked
        // `writeOnly` counts as blocked: it cannot read events, and no further prompt will
        // upgrade it.
        case .denied, .restricted, .writeOnly: .blocked
        @unknown default: .blocked
        }
    }

    static var access: Access { access(for: EKEventStore.authorizationStatus(for: .event)) }

    static var isAuthorized: Bool { access == .available }

    /// Asks for calendar access if it has not been asked for yet. Returns whether the
    /// watcher can use the calendar; a false is a degraded mode, not a failure.
    @discardableResult
    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        // macOS shows the dialog once and never again. Calling `requestFullAccessToEvents`
        // after a refusal returns false without asking anyone anything, so saying "access
        // not granted" would hide the fact that only System Settings can undo it.
        guard access == .notAsked else {
            Log.write("meeting calendar: access was refused earlier — "
                        + "only System Settings can grant it now")
            return false
        }
        // This app has no Dock icon (LSUIElement), so without pulling it forward the
        // permission dialog can open behind the meeting window and never be answered —
        // which is what happened on 2026-08-24, leaving the watcher silently degraded.
        NSApp.activate(ignoringOtherApps: true)
        var granted = false
        do {
            granted = try await store.requestFullAccess()
        } catch {
            Log.write("meeting calendar: access request failed — \(error.localizedDescription)")
        }
        Log.write("meeting calendar: access \(granted ? "granted" : "not granted")")
        return granted
    }

    /// Called when the status flips to available, which can happen in System Settings
    /// while the app is running. An `EKEventStore` that predates the grant can go on
    /// answering with nothing, which would leave the menu saying the calendar is available
    /// while every lookup came back empty.
    static func accessBecameAvailable() {
        Task { await store.reset() }
    }

    /// Says which of the several ways "no calendar" can happen is the one in force. Written
    /// to the log at launch because the difference decides what the user has to do: wait for
    /// the dialog, or go to System Settings.
    static var statusDescription: String {
        switch access {
        case .available: "available"
        case .notAsked: "not asked yet"
        case .blocked: "blocked — only System Settings can grant it now"
        }
    }

    /// Opens the pane where a refusal can be undone, since the dialog will not come back.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The meeting happening right now, or nil. Never throws: no permission, no accounts
    /// and no matching event all mean the same degraded mode to the caller.
    ///
    /// A call already running for more than six hours gets no title. Deliberate, and it
    /// degrades to nil like everything else here.
    static func currentMeeting(at now: Date) async -> MeetingWatcher.CalendarEvent? {
        guard isAuthorized else { return nil }
        // A window wide enough to catch a long call already underway, narrow enough that the
        // predicate stays cheap to run every time a prompt is raised.
        let events = await store.meetings(from: now.addingTimeInterval(-6 * 3600),
                                          to: now.addingTimeInterval(3600))
        return MeetingWatcher.meetingEvent(events, at: now)
    }

    /// Owns the `EKEventStore` off the main actor.
    ///
    /// `events(matching:)` is synchronous, and EventKit's own header says in as many words
    /// to run it somewhere other than the main thread. It can take the better part of a
    /// second the first time an Exchange or CalDAV account is spun up, and it sits on the
    /// critical path of "a call just started, put the panel up and begin recording".
    /// Nothing but plain `Sendable` values crosses back out, which is what
    /// `CalendarEvent` exists for.
    private actor EventStore {
        private var store = EKEventStore()

        func requestFullAccess() async throws -> Bool {
            try await store.requestFullAccessToEvents()
        }

        func reset() { store.reset() }

        func meetings(from: Date, to: Date) -> [MeetingWatcher.CalendarEvent] {
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
            return store.events(matching: predicate).compactMap(Self.descriptor)
        }

        /// Flattens an `EKEvent` into the pure struct the matching logic works on. The three
        /// detail fields are concatenated because a conference link lands in a different one
        /// depending on who sent the invite: Google Calendar puts it in the notes, Teams in
        /// the location, and a hand-typed invite in the URL.
        ///
        /// Returns nil rather than trusting the dates. EventKit declares them
        /// `null_unspecified`, so Swift hands them over implicitly unwrapped, and a
        /// detached or half-materialised occurrence with a nil start would take the whole
        /// process down — from a background app with no window, which the user sees as
        /// Alpiste simply vanishing from the menu bar with nothing in the log.
        private static func descriptor(_ event: EKEvent) -> MeetingWatcher.CalendarEvent? {
            guard let start = event.startDate, let end = event.endDate else { return nil }
            let details = [event.url?.absoluteString, event.location, event.notes]
                .compactMap { $0 }
                .joined(separator: "\n")
            let mine = event.attendees?.first { $0.isCurrentUser }
            return MeetingWatcher.CalendarEvent(
                title: event.title ?? "Meeting",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                details: details,
                // The organiser counts, so a real two-person call reports two.
                attendeeCount: event.attendees?.count ?? 0,
                isCanceled: event.status == .canceled,
                isDeclined: mine?.participantStatus == .declined)
        }
    }
}
