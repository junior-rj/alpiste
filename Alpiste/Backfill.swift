import AppKit
import Foundation

/// Retries the summaries that failed at recording time.
///
/// A recording whose LLM call died still lands on disk with its transcript intact and a
/// placeholder where the summary belongs. Recovering it used to mean noticing the
/// warning and running `--regenerate` by hand; this sweeps those files and fills them in
/// on its own, both at launch and on a schedule after a failure.
@MainActor
enum Backfill {
    /// Only recent notes. A failure that will never resolve — a transcript the model
    /// keeps rejecting, say — would otherwise be retried on every launch forever.
    nonisolated static let window: TimeInterval = 7 * 24 * 3600

    /// Spacing after a failed recording: wide enough for a provider outage to end
    /// between passes, and the last attempt still lands within the hour.
    static let retryDelays: [TimeInterval] = [5 * 60, 15 * 60, 45 * 60]

    struct Result {
        var filled: [URL] = []
        var failed: [(file: URL, reason: String)] = []
        var skipped = false
        /// Nothing left to retry. A skipped pass proves nothing either way, so it never
        /// counts as complete.
        var isComplete: Bool { !skipped && failed.isEmpty }
    }

    private static var scheduled: Task<Void, Never>?
    private static var sweeping = false

    /// One pass at startup, to catch whatever an earlier run left pending.
    static func sweepAtLaunch() {
        Task { await sweep() }
    }

    /// Called when a recording ends without notes. A fresh failure resets the clock
    /// rather than stacking a second schedule on top of the first.
    static func scheduleRetries() {
        scheduled?.cancel()
        let schedule = retryDelays.map { "+\(Int($0 / 60))" }.joined(separator: "/")
        Log.write("backfill: scheduling retries at \(schedule) min")
        scheduled = Task {
            for delay in retryDelays {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                if await sweep().isComplete { return }
            }
            // Every pass is spent and something is still unsummarized. Saying so is the
            // whole point of having deferred the alert at recording time: silence here
            // would leave the note broken with nobody told. The list is re-read rather
            // than remembered, so the alert names only what is still missing.
            Log.write("backfill: retries exhausted, notes still pending")
            AppState.shared.backfillGaveUp(await pendingFiles())
        }
    }

    /// Fills in every recent note missing its summary.
    @discardableResult
    static func sweep() async -> Result {
        // A pass already running will cover these files, so report nothing conclusive
        // and let the schedule keep its own later pass.
        guard !sweeping else { return Result(skipped: true) }
        sweeping = true
        defer { sweeping = false }

        let pending = await pendingFiles()
        guard !pending.isEmpty else { return Result() }
        Log.write("backfill: \(pending.count) note(s) pending — "
                    + pending.map(\.lastPathComponent).joined(separator: ", "))

        var result = Result()
        for (index, file) in pending.enumerated() {
            // Groq's on_demand tier cuts at 8000 tokens per minute counted across
            // requests, and one long transcript is most of that on its own. Back to back,
            // the second note is refused with a 413 — which is a size complaint about a
            // rate limit, and is not in `transientStatuses` — so it falls straight through
            // to Gemini and spends one of its twenty daily requests on a meeting Groq
            // would have taken. Waiting out the window is the whole reason
            // `groqTranscriptLimit` was measured in the first place.
            if index > 0 { try? await Task.sleep(for: .seconds(65)) }
            do {
                try await Notes.regenerate(file: file)
                Log.write("backfill: filled in \(file.lastPathComponent)")
                AppState.shared.noteBackfilled(file)
                result.filled.append(file)
            } catch {
                Log.write("backfill: failed for \(file.lastPathComponent) — "
                            + error.localizedDescription)
                result.failed.append((file, error.localizedDescription))
            }
        }
        return result
    }

    /// Recent `.md` files that have a transcript but no summary, oldest first.
    ///
    /// Off the main actor: this reads every recent note in full, and it runs at launch,
    /// where a season of meetings turns into a visible hitch in the menu bar.
    private static func pendingFiles() async -> [URL] {
        await Task.detached { scan() }.value
    }

    nonisolated private static func scan() -> [URL] {
        let cutoff = Date().addingTimeInterval(-window)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: Notes.outputDirectory, includingPropertiesForKeys: keys) else { return [] }

        var pending: [URL] = []
        for entry in entries where entry.pathExtension == "md" {
            let modified = try? entry.resourceValues(forKeys: Set(keys)).contentModificationDate
            guard (modified ?? .distantPast) > cutoff else { continue }
            guard let contents = try? String(contentsOf: entry, encoding: .utf8) else { continue }
            if Notes.pendingSummary(markdown: contents) { pending.append(entry) }
        }
        // By the timestamp first, then the whole name: the stem is the start time, but a
        // same-minute collision suffix ("-2") sorts before the extension's dot, so plain
        // name order puts the second recording of a minute ahead of the first.
        return pending.sorted {
            ($0.lastPathComponent.prefix(15), $0.lastPathComponent)
                < ($1.lastPathComponent.prefix(15), $1.lastPathComponent)
        }
    }
}
