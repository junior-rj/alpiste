import Foundation

/// Pure routing/retention/sync-state logic for the meetings repo.
/// No app dependencies (Foundation only) so it can be unit-tested with a
/// standalone `swiftc` compile. The impure git side lives in `Sync.swift`.
enum SyncLogic {
    /// The repo subfolder a file belongs in: transcripts get `transcricoes`,
    /// everything else (audio: .m4a, rescued .caf) gets `gravacoes`.
    static func subfolder(for name: String) -> String {
        name.hasSuffix(".md") ? "transcricoes" : "gravacoes"
    }

    /// Where a note's audio may live, in the order to look. In the split layout the
    /// note sits in `transcricoes/` and the audio in the sibling `gravacoes/`; the
    /// note's own folder comes second for the flat legacy layout (`~/MeetingNotes`) and
    /// for any custom folder. Paths only, no filesystem: `--retranscribe` checks
    /// existence and stays inside these folders.
    static func audioFolders(forNoteIn folder: URL) -> [URL] {
        let folder = folder.standardizedFileURL
        guard folder.lastPathComponent == "transcricoes" else { return [folder] }
        let recordings = folder.deletingLastPathComponent()
            .appendingPathComponent("gravacoes", isDirectory: true).standardizedFileURL
        return [recordings, folder]
    }

    /// Names of `.m4a` files whose modification date is strictly older than
    /// `now - maxAgeDays`. Non-`.m4a` files are never returned.
    static func retentionVictims(_ files: [(name: String, modified: Date)],
                                 now: Date, maxAgeDays: Int) -> [String] {
        let cutoff = now.addingTimeInterval(TimeInterval(-maxAgeDays) * 86400)
        return files
            .filter { $0.name.hasSuffix(".m4a") && $0.modified < cutoff }
            .map { $0.name }
    }

    /// Whether the repo has uncommitted transcript changes or unpushed commits.
    static func hasPending(porcelain: String, unpushed: Int) -> Bool {
        if unpushed > 0 { return true }
        return porcelain.split(separator: "\n").contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
