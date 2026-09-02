import Foundation

/// Keeps the display awake for as long as a meeting is being captured or processed.
///
/// Not a convenience. ScreenCaptureKit has no audio-only mode, so the capture is built on a
/// content filter over a *display* (`Recorder.start`), and when that display sleeps replayd
/// tears the stream down with "Failed to find any displays or windows to capture". On
/// 2026-09-02 that ended two meetings mid-sentence, at the exact second `pmset -g log`
/// recorded "Display is turned off", and the note came out short and plausible with nothing
/// saying half the meeting was missing. The modal the teardown raised blamed a closed lid
/// that had never been closed, which sent the diagnosis the wrong way for a while.
///
/// The hold spans the pipeline too, not just the recording: whisper runs for minutes, and a
/// display that sleeps right after the stop would suspend it.
///
/// Deliberately does *not* prevent sleep from a closed lid — nothing can — so the salvage in
/// `AppState.streamFailed` stays exactly as necessary as it was.
///
/// `ProcessInfo.beginActivity` rather than `IOPMAssertionCreateWithName`: it is the same
/// power assertion underneath, without the IOKit import, and the token releases itself if it
/// is ever dropped on the floor.
///
/// Lock rather than `@MainActor` (the only caller is `AppState`, which is main-actor bound):
/// `--selftest` runs its checks from a detached task, and a main-actor guard could not be
/// exercised there without an actor hop around every assertion.
final class SleepGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    /// Idempotent on purpose. A second `beginActivity` would leak the first token, and the
    /// recording that released once would go on holding the machine awake for the rest of
    /// the session with nothing left pointing at it.
    func hold(_ reason: String) {
        lock.lock()
        guard token == nil else { return lock.unlock() }
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: reason)
        lock.unlock()
        Log.write("sleep guard held — \(reason)")
    }

    /// Safe to call having never held anything. Every terminal exit of `start()` and `stop()`
    /// owes this call, the same debt `finishTerminationIfPending()` collects, and making the
    /// redundant calls harmless is what keeps that discipline cheap enough to actually follow.
    func release() {
        lock.lock()
        guard let held = token else { return lock.unlock() }
        ProcessInfo.processInfo.endActivity(held)
        token = nil
        lock.unlock()
        Log.write("sleep guard released")
    }
}
