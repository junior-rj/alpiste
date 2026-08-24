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
    private static let store = EKEventStore()
    private static var accessGranted = false

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
        if isAuthorized {
            accessGranted = true
            return true
        }
        // macOS shows the dialog once and never again. Calling `requestFullAccessToEvents`
        // after a refusal returns false without asking anyone anything, so saying "access
        // not granted" would hide the fact that only System Settings can undo it.
        guard access == .notAsked else {
            accessGranted = false
            Log.write("meeting calendar: access was refused earlier — "
                        + "only System Settings can grant it now")
            return false
        }
        // This app has no Dock icon (LSUIElement), so without pulling it forward the
        // permission dialog can open behind the meeting window and never be answered —
        // which is what happened on 2026-08-24, leaving the watcher silently degraded.
        NSApp.activate(ignoringOtherApps: true)
        do {
            accessGranted = try await store.requestFullAccessToEvents()
        } catch {
            Log.write("meeting calendar: access request failed — \(error.localizedDescription)")
            accessGranted = false
        }
        Log.write("meeting calendar: access \(accessGranted ? "granted" : "not granted")")
        return accessGranted
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

    /// The meeting happening right now, or nil. Never throws and never blocks on permission:
    /// called from the watcher's poll, where a stall would hold up the whole tick.
    static func currentMeeting(at now: Date) -> MeetingWatcher.CalendarEvent? {
        guard isAuthorized else { return nil }
        // A window wide enough to catch a long call already underway, narrow enough that the
        // predicate stays cheap to run every time a prompt is raised.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600),
                                                 end: now.addingTimeInterval(3600),
                                                 calendars: nil)
        let events = store.events(matching: predicate).map(descriptor)
        return MeetingWatcher.meetingEvent(events, at: now)
    }

    /// Flattens an `EKEvent` into the pure struct the matching logic works on. The three
    /// fields are concatenated because a conference link lands in a different one depending
    /// on who sent the invite: Google Calendar puts it in the notes, Teams in the location,
    /// and a hand-typed invite in the URL.
    private static func descriptor(_ event: EKEvent) -> MeetingWatcher.CalendarEvent {
        let details = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: "\n")
        return MeetingWatcher.CalendarEvent(
            title: event.title ?? "Meeting",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            details: details,
            // The organiser counts, so a real two-person call reports two.
            attendeeCount: event.attendees?.count ?? 0)
    }
}
