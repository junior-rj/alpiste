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
///
/// The hold has an owner. `hold` hands back a token and `release` ignores any other: the
/// pipeline of one recording, waking up after its modal "Saved with warnings" alert, used
/// to release the assertion the next recording had just taken, since the watcher keeps
/// ticking inside a modal and can start a new recording while the alert is up.
final class SleepGuard: @unchecked Sendable {
    /// Identifies one hold. Stale tokens are ignored by `release`.
    typealias Token = UInt64

    private let lock = NSLock()
    private var activity: (any NSObjectProtocol)?
    private var owner: Token = 0
    private var generation: Token = 0

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activity != nil
    }

    /// Takes (or takes over) the hold and returns the token that releases it. One
    /// `beginActivity` at a time: a second would leak the first, and the recording that
    /// released once would go on holding the machine awake with nothing pointing at it.
    @discardableResult
    func hold(_ reason: String) -> Token {
        lock.lock()
        generation += 1
        owner = generation
        let fresh = activity == nil
        if fresh {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: reason)
        }
        let token = owner
        lock.unlock()
        Log.write(fresh ? "sleep guard held — \(reason)" : "sleep guard taken over — \(reason)")
        return token
    }

    /// Releases only if `token` is the current owner's. Safe with a stale token or one
    /// already released: every terminal exit of `start()` and `stop()` owes this call, the
    /// same debt `finishTerminationIfPending()` collects, and making the redundant calls
    /// harmless is what keeps that discipline cheap enough to actually follow.
    func release(_ token: Token) {
        lock.lock()
        guard token == owner, let held = activity else { return lock.unlock() }
        ProcessInfo.processInfo.endActivity(held)
        activity = nil
        lock.unlock()
        Log.write("sleep guard released")
    }
}
