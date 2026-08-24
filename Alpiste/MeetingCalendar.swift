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

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks for calendar access if it has not been asked for yet. Returns whether the
    /// watcher can use the calendar; a false is a degraded mode, not a failure.
    @discardableResult
    static func requestAccess() async -> Bool {
        if isAuthorized {
            accessGranted = true
            return true
        }
        do {
            accessGranted = try await store.requestFullAccessToEvents()
        } catch {
            Log.write("meeting calendar: access request failed — \(error.localizedDescription)")
            accessGranted = false
        }
        Log.write("meeting calendar: access \(accessGranted ? "granted" : "not granted")")
        return accessGranted
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
