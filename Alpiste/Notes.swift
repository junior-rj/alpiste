import Foundation

/// Everything that happens after the recording stops: mix, transcribe, summarize, save.
enum Notes {
    static let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("MeetingNotes", isDirectory: true)

    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Alpiste", isDirectory: true)

    static var modelURL: URL {
        supportDirectory.appendingPathComponent("models/ggml-medium.bin")
    }

    // MARK: - Pipeline

    /// Runs the full pipeline. Never throws: whatever succeeds gets written to disk.
    /// A failed API call must never cost the user their recording.
    static func process(_ capture: Recorder.Capture,
                        startedAt: Date,
                        progress: @Sendable (String) -> Void = { _ in })
        async -> (file: URL?, problems: [String]) {
        var problems: [String] = []
        let stamp = Self.stamp(startedAt)

        do {
            try FileManager.default.createDirectory(at: outputDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            return (nil, ["Could not create \(outputDirectory.path): \(error.localizedDescription)"])
        }

        // 1. Mix the two sources down to one keepable m4a plus the 16 kHz wav whisper needs.
        var audioFile: URL?
        var wav16k: URL?
        do {
            progress("Mixing audio…")
            let mixed = try mix(capture)
            wav16k = mixed.wav16k
            let destination = outputDirectory.appendingPathComponent("\(stamp).m4a")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: mixed.m4a, to: destination)
            audioFile = destination
        } catch {
            problems.append("Audio mixing failed: \(error.localizedDescription)")
        }

        // 2. Transcribe. Local model wins; the API is only a fallback.
        var transcript = ""
        if let wav16k {
            do {
                progress("Transcribing…")
                transcript = try await transcribe(wav16k)
            } catch {
                problems.append("Transcription failed: \(error.localizedDescription)")
            }
        }

        // 3. Summarize. Offline or keyless is a normal outcome, not an error.
        var notes: String?
        if !transcript.isEmpty {
            do {
                progress("Writing notes…")
                notes = try await summarize(transcript)
            } catch {
                problems.append("Note generation failed: \(error.localizedDescription)")
            }
        }

        // 4. Always write the file.
        let markdown = Self.markdown(title: Self.title(startedAt),
                                     notes: notes,
                                     transcript: transcript,
                                     audioFile: audioFile?.lastPathComponent,
                                     problems: problems)
        let destination = outputDirectory.appendingPathComponent("\(stamp).md")
        do {
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            problems.append("Could not write notes: \(error.localizedDescription)")
            return (nil, problems)
        }

        try? FileManager.default.removeItem(at: capture.directory)
        return (destination, problems)
    }

    // MARK: - Mixing

    struct Mixed {
        let m4a: URL
        let wav16k: URL
    }

    static func mix(_ capture: Recorder.Capture) throws -> Mixed {
        guard let ffmpeg = Tool.find("ffmpeg") else { throw Failure.missingTool("ffmpeg") }
        let inputs = [capture.systemAudio, capture.microphone].compactMap { $0 }
        guard !inputs.isEmpty else { throw Failure.noAudioCaptured }

        let m4a = capture.directory.appendingPathComponent("meeting.m4a")
        let wav = capture.directory.appendingPathComponent("16k.wav")

        var args = ["-y", "-nostdin"]
        for input in inputs { args += ["-i", input.path] }

        // Both outputs must be fed explicitly. Without -map the second output file
        // consumes the input streams and starves the filtergraph, and ffmpeg fails with
        // "Cannot find an unused audio input stream to feed the unlabeled input pad".
        let m4aSource: String
        let wavSource: String
        if inputs.count > 1 {
            // normalize=0 keeps each source at its original level instead of halving both.
            let pads = (0..<inputs.count).map { "[\($0):a]" }.joined()
            args += ["-filter_complex",
                     "\(pads)amix=inputs=\(inputs.count):duration=longest:normalize=0,asplit=2[mix][whisper]"]
            m4aSource = "[mix]"
            wavSource = "[whisper]"
        } else {
            m4aSource = "0:a"
            wavSource = "0:a"
        }

        // Keepable copy: mono 64k AAC is ~28 MB/hour and plenty for speech.
        args += ["-map", m4aSource, "-c:a", "aac", "-b:a", "64k", "-ac", "1", m4a.path]
        // Whisper only accepts 16 kHz mono PCM.
        args += ["-map", wavSource, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", wav.path]

        try Tool.run(ffmpeg, args, in: capture.directory, label: "ffmpeg")
        return Mixed(m4a: m4a, wav16k: wav)
    }

    // MARK: - Transcription

    static func transcribe(_ wav: URL) async throws -> String {
        if FileManager.default.fileExists(atPath: modelURL.path),
           let whisper = Tool.find("whisper-cli") {
            return try transcribeLocally(wav, whisper: whisper)
        }
        return try await transcribeViaAPI(wav)
    }

    private static func transcribeLocally(_ wav: URL, whisper: URL) throws -> String {
        let prefix = wav.deletingPathExtension()
        try Tool.run(whisper,
                     ["-m", modelURL.path, "-f", wav.path, "-l", "auto",
                      "-otxt", "-of", prefix.path, "-np"],
                     in: wav.deletingLastPathComponent(),
                     label: "whisper-cli")
        let text = try String(contentsOf: prefix.appendingPathExtension("txt"), encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OpenAI-compatible Whisper endpoint. Groq first: it has a free tier.
    private static func transcribeViaAPI(_ wav: URL) async throws -> String {
        let env = Env.load()
        let provider: (key: String, url: String, model: String)
        if let key = env["GROQ_API_KEY"], !key.isEmpty {
            provider = (key, "https://api.groq.com/openai/v1/audio/transcriptions",
                        env["GROQ_WHISPER_MODEL"] ?? "whisper-large-v3-turbo")
        } else if let key = env["OPENAI_API_KEY"], !key.isEmpty {
            provider = (key, "https://api.openai.com/v1/audio/transcriptions",
                        env["OPENAI_WHISPER_MODEL"] ?? "whisper-1")
        } else {
            throw Failure.noTranscriber
        }

        // The 16 kHz wav is ~115 MB/hour, well past the 25 MB upload caps. Compress
        // a throwaway copy; only this fallback branch pays for it.
        let upload = wav.deletingLastPathComponent().appendingPathComponent("upload.m4a")
        if let ffmpeg = Tool.find("ffmpeg") {
            try? Tool.run(ffmpeg,
                          ["-y", "-nostdin", "-i", wav.path, "-c:a", "aac", "-b:a", "16k", upload.path],
                          in: wav.deletingLastPathComponent(), label: "ffmpeg")
        }
        let payload = FileManager.default.fileExists(atPath: upload.path) ? upload : wav

        let boundary = "alpiste-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", provider.model)
        field("response_format", "json")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(payload.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(try Data(contentsOf: payload))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: provider.url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(provider.key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        try Self.checkHTTP(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw Failure.badResponse("transcription response had no `text` field")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Summarization

    static let prompt = """
        You are summarizing a meeting transcript. The transcript comes from automatic \
        speech recognition, so expect errors and no speaker labels; infer speakers from \
        context where you reasonably can.

        Reply with GitHub-flavored Markdown containing exactly these three sections, in \
        this order, and nothing else. No preamble, no closing remarks, no code fences.

        ## Summary
        Exactly 5 bullets covering what the meeting was about and what came out of it.

        ## Decisions
        One bullet per decision actually made. If none were made, write a single bullet: \
        "No decisions were recorded."

        ## Action Items
        One bullet per task, formatted as `- [ ] **Owner** — task`. Use "Unassigned" when \
        no owner is identifiable. If there are none, write a single bullet: \
        "No action items were recorded."

        Write in the same language as the transcript.

        Transcript:
        """

    static func summarize(_ transcript: String) async throws -> String {
        let env = Env.load()
        guard let key = env["GEMINI_API_KEY"], !key.isEmpty else { throw Failure.noLLMKey }
        // An alias, not a pinned version, so this doesn't rot when models turn over.
        let model = env["GEMINI_MODEL"] ?? "gemini-flash-latest"

        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": "\(prompt)\n\n\(transcript)"]]]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkHTTP(response, data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw Failure.badResponse("Gemini returned no candidates")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.badResponse("Gemini returned an empty response")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output

    /// Pure: assembles the final file. Covered by `--selftest`.
    static func markdown(title: String,
                         notes: String?,
                         transcript: String,
                         audioFile: String?,
                         problems: [String]) -> String {
        var out = "# \(title)\n\n"
        if let audioFile { out += "Audio: `\(audioFile)`\n\n" }
        if !problems.isEmpty {
            out += "> **Alpiste hit some problems:**\n"
            for problem in problems { out += "> - \(problem)\n" }
            out += "\n"
        }
        out += (notes ?? "_No notes were generated. The transcript is below._") + "\n\n"
        out += "---\n\n## Transcript\n\n"
        out += transcript.isEmpty ? "_No transcript was produced._\n" : transcript + "\n"
        return out
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    static func title(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting Notes: \(formatter.string(from: date))"
    }

    private static func checkHTTP(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
        throw Failure.badResponse("HTTP \(http.statusCode): \(body)")
    }

    enum Failure: LocalizedError {
        case missingTool(String)
        case noAudioCaptured
        case noTranscriber
        case noLLMKey
        case commandFailed(String, Int32, String)
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .missingTool(let name):
                "`\(name)` not found. Run scripts/setup.sh."
            case .noAudioCaptured:
                "No audio was captured. Check the Screen Recording and Microphone permissions."
            case .noTranscriber:
                "No local model at \(Notes.modelURL.path) and no GROQ_API_KEY or OPENAI_API_KEY set."
            case .noLLMKey:
                "No GEMINI_API_KEY set, so the transcript was saved without notes."
            case .commandFailed(let name, let code, let log):
                "\(name) exited with code \(code). \(log)"
            case .badResponse(let detail):
                detail
            }
        }
    }
}

// MARK: - Subprocess

enum Tool {
    /// A GUI app launched from Finder gets a bare PATH without /opt/homebrew/bin, so
    /// binaries have to be located explicitly. Every subprocess call goes through here.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func find(_ name: String) -> URL? {
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Runs to completion with output redirected to a log file. Redirecting rather than
    /// piping avoids the deadlock you get when a chatty child fills the pipe buffer.
    static func run(_ executable: URL, _ args: [String], in directory: URL, label: String) throws {
        let log = directory.appendingPathComponent("\(label).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: log) else {
            throw Notes.Failure.commandFailed(label, -1, "could not open log file")
        }
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let tail = (try? String(contentsOf: log, encoding: .utf8))?
                .split(separator: "\n").suffix(6).joined(separator: " ") ?? ""
            throw Notes.Failure.commandFailed(label, process.terminationStatus, String(tail.suffix(400)))
        }
    }
}

// MARK: - Config

enum Env {
    /// A fixed absolute path: a repo-relative .env is unreachable once the .app is
    /// installed somewhere else. Real environment variables win over the file.
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".alpiste/.env")

    static func load() -> [String: String] {
        var values = parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
        for key in ["GEMINI_API_KEY", "GEMINI_MODEL", "GROQ_API_KEY",
                    "GROQ_WHISPER_MODEL", "OPENAI_API_KEY", "OPENAI_WHISPER_MODEL"] {
            if let override = ProcessInfo.processInfo.environment[key], !override.isEmpty {
                values[key] = override
            }
        }
        return values
    }

    /// Pure: KEY=VALUE, optional `export`, full-line `#` comments, optional quoting.
    /// Covered by `--selftest`.
    static func parse(_ contents: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            // Split on the first `=` only, so values may contain more of them.
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'",
               value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { values[key] = value }
        }
        return values
    }
}
