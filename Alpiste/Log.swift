import Foundation

/// A record of what the app did, on disk, that outlives the alert that reported it.
///
/// Everything here used to go to `print()`, which is discarded when the `.app` is
/// launched from the Finder, or to `NSLog`, which on 2026-08-20 did not reach the
/// unified log at all. That left a modal alert as the only account of a failure, and it
/// vanished the moment it was dismissed. Reconstructing that day's failed summary meant
/// reading Apple's own CFNetwork logging, which happens to record request sizes and
/// status codes and rotates out within a fortnight.
///
/// So: an ordinary text file, in the folder macOS reserves for exactly this, reachable
/// from the menu bar. It is meant to be handed over as-is.
///
/// **Never write a secret or meeting content here.** Log the name of a key, never its
/// value; the size of a transcript, never its text.
enum Log {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Alpiste")
    static let file = directory.appendingPathComponent("alpiste.log")
    private static let previous = directory.appendingPathComponent("alpiste.log.1")

    /// Rotating at 2 MB keeps roughly a season of meetings while staying small enough to
    /// attach to a message. One old file is kept, so a rotation mid-investigation does
    /// not destroy the very lines being looked for.
    private static let maximumBytes = 2 * 1024 * 1024

    /// Writes are serialized: the recording pipeline and a backfill sweep can be logging
    /// at the same moment, and interleaved halves of two lines would be worse than
    /// either line alone.
    private static let queue = DispatchQueue(label: "com.sparrow.alpiste.log")

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        // One event, one line, always. An HTTP error body arrives as pretty-printed
        // JSON, and left alone a single Gemini failure sprawls over fifteen lines —
        // which defeats both reading the file and grepping it.
        let flattened = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let line = "\(timestamp.string(from: Date()))  \(flattened)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded()
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            guard FileManager.default.fileExists(atPath: file.path) else {
                _ = try? data.write(to: file)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    /// Blocks until every queued line has been written. Required before `exit()`: the
    /// `--regenerate` and `--backfill` paths would otherwise lose the very line that
    /// says how they ended.
    static func flush() {
        queue.sync {}
    }

    /// The log file, guaranteed to exist and to have every pending line already in it.
    /// Writes are queued, so opening the file straight after a `write` could otherwise
    /// hand the user a stale — or on first launch, missing — file.
    static func flushed() -> URL {
        flush()
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        return file
    }

    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int
        guard let size, size > maximumBytes else { return }
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: file, to: previous)
    }

    /// Opens the session that follows, so a log read weeks later still shows which
    /// build produced the lines under it.
    static func startup(_ context: String) {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        write("--- Alpiste \(version) (\(build)) \(context) ---")
    }
}
