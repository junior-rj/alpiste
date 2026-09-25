import Foundation

// Tiny assert harness: compiled together with SyncLogic.swift via swiftc.
// Run: swiftc Alpiste/SyncLogic.swift Tests/SyncLogicTests.swift -o /tmp/synclogic_tests && /tmp/synclogic_tests
@main
enum SyncLogicTests {
    static var failures = 0

    static func expect(_ cond: Bool, _ label: String) {
        if cond { print("ok - \(label)") }
        else { print("FAIL - \(label)"); failures += 1 }
    }

    static func main() {
        // subfolder routing
        expect(SyncLogic.subfolder(for: "2026-09-11-0930.md") == "transcricoes", "md -> transcricoes")
        expect(SyncLogic.subfolder(for: "2026-09-11-0930.m4a") == "gravacoes", "m4a -> gravacoes")
        expect(SyncLogic.subfolder(for: "2026-09-11-0930-system.caf") == "gravacoes", "caf -> gravacoes")

        // retention: only .m4a older than maxAgeDays
        let now = ISO8601DateFormatter().date(from: "2026-09-13T12:00:00Z")!
        func daysAgo(_ d: Int) -> Date { now.addingTimeInterval(TimeInterval(-d) * 86400) }
        let files: [(name: String, modified: Date)] = [
            ("old.m4a", daysAgo(61)),
            ("fresh.m4a", daysAgo(59)),
            ("old.md", daysAgo(400)),          // never a victim: not .m4a
            ("edge.m4a", daysAgo(60)),          // exactly 60 days: not older than cutoff, kept
        ]
        let victims = SyncLogic.retentionVictims(files, now: now, maxAgeDays: 60)
        expect(victims == ["old.m4a"], "retention picks only old.m4a, got \(victims)")

        // audioFolders: where --retranscribe looks for the note's audio, in order
        let split = URL(fileURLWithPath: "/r/reunioes/transcricoes", isDirectory: true)
        expect(SyncLogic.audioFolders(forNoteIn: split).map(\.path) == ["/r/reunioes/gravacoes", "/r/reunioes/transcricoes"],
               "split layout: sibling gravacoes first, then the note's own folder")
        let flat = URL(fileURLWithPath: "/Users/x/MeetingNotes", isDirectory: true)
        expect(SyncLogic.audioFolders(forNoteIn: flat).map(\.path) == ["/Users/x/MeetingNotes"],
               "flat layout: only the note's own folder")

        // hasPending
        expect(SyncLogic.hasPending(porcelain: "", unpushed: 0) == false, "clean -> no pending")
        expect(SyncLogic.hasPending(porcelain: " M transcricoes/x.md\n", unpushed: 0) == true, "dirty -> pending")
        expect(SyncLogic.hasPending(porcelain: "", unpushed: 2) == true, "unpushed -> pending")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }
}
