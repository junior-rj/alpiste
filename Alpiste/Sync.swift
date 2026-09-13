import Foundation

/// Commits new transcripts and pushes them to the meetings repo.
/// Impure counterpart of SyncLogic. Self-contained (no Tool/Notes.Failure):
/// Tool.run hardcodes its environment, which would drop GIT_TERMINAL_PROMPT.
/// Never throws: a sync failure must not lose a note already written to disk;
/// it is logged and retried by Backfill on the next launch/sweep.
enum Sync {
    private static let timeout: TimeInterval = 120
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    private static func gitURL() -> URL? {
        for d in searchPaths {
            let c = URL(fileURLWithPath: d).appendingPathComponent("git")
            if FileManager.default.isExecutableFile(atPath: c.path) { return c }
        }
        return nil
    }

    private static func gitEnv() -> [String: String] {
        ["PATH": searchPaths.joined(separator: ":"),
         "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
         "LANG": "en_US.UTF-8",
         "GIT_TERMINAL_PROMPT": "0"]
    }

    /// Run one git subcommand with `-C repo`. Output goes to a per-call log
    /// under supportDirectory (never piped: avoids buffer deadlock). Returns
    /// the exit status; -1 if git is missing or the launch/timeout fails.
    @discardableResult
    private static func run(_ args: [String], repo: URL, label: String) async -> Int32 {
        guard let git = gitURL() else { Log.write("git not found for \(label)"); return -1 }
        let logURL = Notes.supportDirectory.appendingPathComponent("\(label).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        defer { try? handle?.close() }
        let p = Process()
        p.executableURL = git
        p.arguments = ["-C", repo.path] + args
        p.environment = gitEnv()
        if let handle { p.standardOutput = handle; p.standardError = handle }
        do { try p.run() } catch { Log.write("git \(label) launch failed: \(error)"); return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds: 200_000_000) }
        if p.isRunning { p.terminate(); Log.write("git \(label) timed out"); return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// Add transcripts, commit if anything is staged, rebase, push. Never throws.
    static func push(reason: String) async {
        let repo = Notes.outputDirectory
        guard await run(["add", "transcricoes"], repo: repo, label: "git-add") == 0 else {
            Log.write("sync FAILED (\(reason)): git add"); return
        }
        // `diff --cached --quiet` exits non-zero when something is staged.
        let staged = await run(["diff", "--cached", "--quiet"], repo: repo, label: "git-staged") != 0
        if staged {
            guard await run(["commit", "-m", "transcricao: \(reason)"], repo: repo, label: "git-commit") == 0 else {
                Log.write("sync FAILED (\(reason)): git commit"); return
            }
        }
        guard await run(["pull", "--rebase"], repo: repo, label: "git-pull") == 0 else {
            Log.write("sync FAILED (\(reason)): git pull --rebase"); return
        }
        guard await run(["push"], repo: repo, label: "git-push") == 0 else {
            Log.write("sync FAILED (\(reason)): git push"); return
        }
        Log.write("sync ok (\(reason))")
    }

    /// Snapshot of pending work for Backfill's retry decision.
    static func pendingState(repo: URL) -> (porcelain: String, unpushed: Int) {
        let porcelain = capture(["status", "--porcelain", "--", "transcricoes"], repo: repo)
        let unpushed = Int(capture(["rev-list", "--count", "@{u}..HEAD"], repo: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (porcelain, unpushed)
    }

    /// Synchronous git capturing stdout, for the small read-only status queries.
    private static func capture(_ args: [String], repo: URL) -> String {
        guard let git = gitURL() else { return "" }
        let p = Process()
        p.executableURL = git
        p.arguments = ["-C", repo.path] + args
        p.environment = gitEnv()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
