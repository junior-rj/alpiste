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

        do {
            try FileManager.default.createDirectory(at: outputDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            return (nil, ["Could not create \(outputDirectory.path): \(error.localizedDescription)"])
        }

        // A collision only happens if two recordings start in the same minute; suffix
        // rather than overwrite, since overwriting would silently destroy the earlier one.
        let stem = Self.uniqueStem(Self.stamp(startedAt)) { candidate in
            ["md", "m4a"].contains { ext in
                FileManager.default.fileExists(
                    atPath: outputDirectory.appendingPathComponent("\(candidate).\(ext)").path)
            }
        }

        // 1. Mix the two sources down to one keepable m4a plus the 16 kHz wav whisper needs.
        var audioFile: URL?
        var wav16k: URL?
        do {
            progress("Mixing audio…")
            let mixed = try await mix(capture)
            wav16k = mixed.wav16k
            let destination = outputDirectory.appendingPathComponent("\(stem).m4a")
            try FileManager.default.moveItem(at: mixed.m4a, to: destination)
            audioFile = destination
        } catch {
            problems.append("Audio mixing failed: \(error.localizedDescription)")
            // The raw .caf files are the only surviving copy of the meeting; rescue them
            // before the temp capture directory is ever removed.
            problems.append(contentsOf: rescueRawAudio(capture, stem: stem))
        }

        // 2. Transcribe. Local model wins; the API is only a fallback.
        var transcript = ""
        if let wav16k {
            do {
                progress("Transcribing…")
                let transcribed = try await transcribe(wav16k)
                transcript = transcribed.text
                if let warning = transcribed.warning { problems.append(warning) }
                if transcript.isEmpty {
                    problems.append("Transcription succeeded but produced no text (silent recording?).")
                }
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
        let captured = [capture.systemAudio != nil ? "system audio" : nil,
                        capture.microphone != nil ? "microphone" : nil].compactMap { $0 }
        let markdown = Self.markdown(title: Self.title(startedAt),
                                     notes: notes,
                                     transcript: transcript,
                                     audioFile: audioFile?.lastPathComponent,
                                     sources: captured.isEmpty ? nil : captured.joined(separator: " + "),
                                     problems: problems)
        let destination = outputDirectory.appendingPathComponent("\(stem).md")
        do {
            try markdown.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            problems.append("Could not write \(destination.path): \(error.localizedDescription)")
            let fallback = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/\(stem).md")
            if (try? markdown.write(to: fallback, atomically: true, encoding: .utf8)) != nil {
                problems.append("Saved to \(fallback.path) instead.")
                try? FileManager.default.removeItem(at: capture.directory)
                return (fallback, problems)
            }
            problems.append("Raw files left in \(capture.directory.path).")
            return (nil, problems)
        }

        try? FileManager.default.removeItem(at: capture.directory)
        return (destination, problems)
    }

    /// Pure: appends -2, -3… until neither `<stem>.md` nor `<stem>.m4a` (per `exists`)
    /// is taken. Two recordings started in the same minute must not collide.
    /// Covered by `--selftest`.
    static func uniqueStem(_ base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Called when `mix()` fails: the raw .caf files are the only remaining copy of the
    /// meeting, so move them next to where the .md will land instead of losing them when
    /// the temp capture directory is cleaned up.
    private static func rescueRawAudio(_ capture: Recorder.Capture, stem: String) -> [String] {
        var rescued: [String] = []
        for (raw, suffix) in [(capture.systemAudio, "system"), (capture.microphone, "mic")] {
            guard let raw, FileManager.default.fileExists(atPath: raw.path) else { continue }
            let dest = outputDirectory.appendingPathComponent("\(stem)-\(suffix).caf")
            if (try? FileManager.default.moveItem(at: raw, to: dest)) != nil {
                rescued.append(dest.lastPathComponent)
            }
        }
        return rescued.isEmpty
            ? ["Raw audio left in \(capture.directory.path)."]
            : ["Raw audio preserved as \(rescued.joined(separator: ", "))."]
    }

    // MARK: - Mixing

    struct Mixed {
        let m4a: URL
        let wav16k: URL
    }

    static func mix(_ capture: Recorder.Capture) async throws -> Mixed {
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
            // alimiter catches the peaks that summing at full level produces. Without it
            // a loud meeting plus a loud mic clips at 0 dBFS; blanket volume reduction
            // would instead penalise quiet meetings, so limit rather than attenuate.
            args += ["-filter_complex",
                     "\(pads)amix=inputs=\(inputs.count):duration=longest:normalize=0,"
                        + "alimiter=limit=0.95,asplit=2[mix][whisper]"]
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

        try await Tool.run(ffmpeg, args, in: capture.directory, label: "ffmpeg")
        return Mixed(m4a: m4a, wav16k: wav)
    }

    // MARK: - Transcription

    static func transcribe(_ wav: URL) async throws -> (text: String, warning: String?) {
        if FileManager.default.fileExists(atPath: modelURL.path),
           let whisper = Tool.find("whisper-cli") {
            do {
                return (try await transcribeLocally(wav, whisper: whisper), nil)
            } catch {
                // The model/binary are present but broke at runtime (corrupt download,
                // OOM, crash): fall back to the API instead of losing the transcript,
                // same as if the local model had never been installed.
                let env = Env.load()
                let hasFallbackKey = ["GROQ_API_KEY", "OPENAI_API_KEY"]
                    .contains { !(env[$0] ?? "").isEmpty }
                guard hasFallbackKey else { throw error }
                let text = try await transcribeViaAPI(wav)
                return (text, "Local transcription failed (\(error.localizedDescription)); used the API fallback.")
            }
        }
        return (try await transcribeViaAPI(wav), nil)
    }

    private static func transcribeLocally(_ wav: URL, whisper: URL) async throws -> String {
        let prefix = wav.deletingPathExtension()
        // The medium model can take a long time on a long meeting; give it room to finish.
        try await Tool.run(whisper,
                           ["-m", modelURL.path, "-f", wav.path, "-l", "auto",
                            "-otxt", "-of", prefix.path, "-np"],
                           in: wav.deletingLastPathComponent(),
                           label: "whisper-cli", timeout: 4 * 3600)
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
        // a throwaway copy; only this fallback branch pays for it. If ffmpeg dies
        // partway through, fall back to the uncompressed wav rather than risk
        // uploading a truncated file that looks present but isn't valid audio.
        var payload = wav
        if let ffmpeg = Tool.find("ffmpeg") {
            let upload = wav.deletingLastPathComponent().appendingPathComponent("upload.m4a")
            do {
                try await Tool.run(ffmpeg,
                                   ["-y", "-nostdin", "-i", wav.path, "-c:a", "aac", "-b:a", "16k", upload.path],
                                   in: wav.deletingLastPathComponent(), label: "ffmpeg-upload")
                payload = upload
            } catch { /* keep the uncompressed wav */ }
        }

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

        guard let endpoint = URL(string: provider.url) else {
            throw Failure.badResponse("invalid transcription endpoint: \(provider.url)")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(provider.key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data = try await Self.fetchWithRetry(request, uploading: body)
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

    enum Summarizer: String {
        case groq = "Groq"
        case gemini = "Gemini"

        var keyName: String {
            switch self {
            case .groq: "GROQ_API_KEY"
            case .gemini: "GEMINI_API_KEY"
            }
        }
    }

    /// Pure: the summarizers that are configured, in the order to try them. Groq leads
    /// on measured reliability, not preference: Gemini's free tier caps at 20 requests a
    /// day and left three meetings unsummarized across two days, one of them unnoticed
    /// for a day. Gemini stays as the fallback, where its far larger context window is
    /// the safety net for a meeting long enough to overflow Groq. Covered by `--selftest`.
    static func summaryProviders(_ env: [String: String]) -> [Summarizer] {
        [.groq, .gemini].filter { !(env[$0.keyName] ?? "").isEmpty }
    }

    /// Two independent providers, so an outage on one no longer costs a meeting's
    /// summary. Every provider's failure is reported: knowing both misbehaved is what
    /// separates "the note is missing" from "the note is missing and here is why".
    static func summarize(_ transcript: String) async throws -> String {
        let env = Env.load()
        let providers = summaryProviders(env)
        guard !providers.isEmpty else { throw Failure.noLLMKey }

        var failures: [String] = []
        for provider in providers {
            let key = env[provider.keyName] ?? ""
            do {
                switch provider {
                case .groq: return try await summarizeViaGroq(transcript, key: key, env: env)
                case .gemini: return try await summarizeViaGemini(transcript, key: key, env: env)
                }
            } catch {
                failures.append("\(provider.rawValue): \(error.localizedDescription)")
            }
        }
        throw Failure.badResponse(failures.joined(separator: " / "))
    }

    private static func summarizeViaGemini(_ transcript: String, key: String,
                                           env: [String: String]) async throws -> String {
        // An alias, not a pinned version, so this doesn't rot when models turn over.
        let model = env["GEMINI_MODEL"] ?? "gemini-flash-latest"
        guard model.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
        else {
            throw Failure.badResponse("GEMINI_MODEL is not a valid model name: \(model)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": "\(prompt)\n\n\(transcript)"]]]]
        ])

        let data = try await Self.fetchWithRetry(request)
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

    /// Groq's OpenAI-compatible chat endpoint. Unlike Gemini the model name only ever
    /// reaches the JSON body, so it needs no character validation.
    private static func summarizeViaGroq(_ transcript: String, key: String,
                                         env: [String: String]) async throws -> String {
        // Groq's free catalog turns over (the Llama 3.3 default this shipped with was
        // withdrawn within the day). `GROQ_MODEL` is the escape hatch; the current list
        // is at https://api.groq.com/openai/v1/models.
        let model = env["GROQ_MODEL"] ?? "openai/gpt-oss-120b"
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw Failure.badResponse("invalid Groq endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "\(prompt)\n\n\(transcript)"]],
        ])

        let data = try await Self.fetchWithRetry(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw Failure.badResponse("Groq returned no choices")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.badResponse("Groq returned an empty response")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output

    /// Written in place of the notes when summarization produced nothing. Doubles as the
    /// marker the backfill sweep looks for, so the two must stay in sync.
    static let noNotesPlaceholder = "_No notes were generated. The transcript is below._"

    /// Separates the notes from the transcript. `split` and `pendingSummary` both key
    /// off it, so it lives in one place.
    static let transcriptDivider = "\n---\n\n## Transcript\n\n"

    /// Pure: assembles the final file. Covered by `--selftest`.
    static func markdown(title: String,
                         notes: String?,
                         transcript: String,
                         audioFile: String?,
                         sources: String? = nil,
                         problems: [String]) -> String {
        var out = "# \(title)\n\n"
        if let audioFile {
            // Naming the captured sources is the only way to tell afterwards whether the
            // mic actually made it in; a silent participant looks identical to a dead mic.
            out += "Audio: `\(audioFile)`" + (sources.map { " — \($0)" } ?? "") + "\n\n"
        }
        if !problems.isEmpty {
            out += "> **Alpiste hit some problems:**\n"
            for problem in problems { out += "> - \(problem)\n" }
            out += "\n"
        }
        out += (notes ?? noNotesPlaceholder) + "\n"
        out += transcriptDivider
        out += transcript.isEmpty ? "_No transcript was produced._\n" : transcript + "\n"
        return out
    }

    /// Pure: pulls the reusable parts back out of a written note file so the summary
    /// can be regenerated. Returns the title and audio lines verbatim plus the
    /// transcript; the problems blockquote and the no-notes placeholder are exactly
    /// what regeneration replaces, so they are dropped. Covered by `--selftest`.
    static func split(markdown: String) -> (header: String, transcript: String)? {
        guard let range = markdown.range(of: transcriptDivider) else { return nil }
        let transcript = String(markdown[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty, transcript != "_No transcript was produced._" else { return nil }
        let kept = markdown[..<range.lowerBound].split(separator: "\n").filter {
            $0.hasPrefix("# ") || $0.hasPrefix("Audio: ")
        }
        guard kept.first?.hasPrefix("# ") == true else { return nil }
        return (kept.joined(separator: "\n\n"), transcript)
    }

    /// Pure: true when a saved note still has a transcript worth summarizing but no
    /// notes, which is exactly what the backfill sweep retries. A note that failed to
    /// transcribe at all is not pending: there is nothing to feed the LLM.
    /// Covered by `--selftest`.
    static func pendingSummary(markdown: String) -> Bool {
        guard split(markdown: markdown) != nil,
              let divider = markdown.range(of: transcriptDivider) else { return false }
        // Only above the divider: a transcript that happens to quote the placeholder
        // must not make a finished note look pending.
        return markdown[..<divider.lowerBound].contains(noNotesPlaceholder)
    }

    /// Re-runs summarization on an already-written note file, in place. Backs
    /// `--regenerate`, the recovery path for when the LLM was down at recording time.
    static func regenerate(file: URL) async throws {
        let contents = try String(contentsOf: file, encoding: .utf8)
        guard let parts = split(markdown: contents) else {
            throw Failure.badResponse("\(file.lastPathComponent) has no transcript to summarize")
        }
        let notes = try await summarize(parts.transcript)
        let rebuilt = parts.header + "\n\n" + notes + "\n\n---\n\n## Transcript\n\n"
            + parts.transcript + "\n"
        try rebuilt.write(to: file, atomically: true, encoding: .utf8)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        // Fixed locale/calendar: a system set to a non-Gregorian calendar would
        // otherwise produce a "yyyy" that isn't the Gregorian year, breaking both
        // the filename format and its chronological sort order.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    static func title(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting Notes: \(formatter.string(from: date))"
    }

    private static func checkHTTP(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
        throw Failure.http(http.statusCode, body)
    }

    private static let transientStatuses: Set<Int> = [429, 500, 502, 503, 504]

    /// Free-tier Gemini and Groq throw transient 429/5xx under load, so spaced retries
    /// (2s/4s/8s) usually ride the spike out. A `Retry-After` header, when present,
    /// overrides the backoff. Non-transient errors propagate at once. `uploading`
    /// makes this double as the transcription upload's retry path, since a dropped
    /// 429 there loses the whole transcript, not just the summary.
    private static func fetchWithRetry(_ request: URLRequest, uploading body: Data? = nil,
                                       attempts: Int = 4) async throws -> Data {
        func send() async throws -> (Data, URLResponse) {
            if let body {
                try await URLSession.shared.upload(for: request, from: body)
            } else {
                try await URLSession.shared.data(for: request)
            }
        }

        for attempt in 1..<attempts {
            do {
                let (data, response) = try await send()
                if let http = response as? HTTPURLResponse, transientStatuses.contains(http.statusCode) {
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    try await Task.sleep(for: .seconds(min(retryAfter ?? Double(1 << attempt), 60)))
                    continue
                }
                try checkHTTP(response, data)
                return data
            } catch where isTransient(error) {
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        let (data, response) = try await send()
        try checkHTTP(response, data)
        return data
    }

    private static func isTransient(_ error: Error) -> Bool {
        if case Failure.http(let status, _) = error {
            return transientStatuses.contains(status)
        }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                    .dnsLookupFailed, .cannotFindHost].contains(urlError.code)
        }
        return false
    }

    enum Failure: LocalizedError {
        case missingTool(String)
        case noAudioCaptured
        case noTranscriber
        case noLLMKey
        case commandFailed(String, Int32, String)
        case badResponse(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .missingTool(let name):
                "`\(name)` not found. Run scripts/setup.sh."
            case .noAudioCaptured:
                "No audio was captured. Check the Screen Recording and Microphone permissions."
            case .noTranscriber:
                "No local model at \(Notes.modelURL.path) and no GROQ_API_KEY or OPENAI_API_KEY set."
            case .noLLMKey:
                "No GEMINI_API_KEY or GROQ_API_KEY set, so the transcript was saved without notes."
            case .commandFailed(let name, let code, let log):
                "\(name) exited with code \(code). \(log)"
            case .badResponse(let detail):
                detail
            case .http(let status, let body):
                "HTTP \(status): \(body)"
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
    /// Waits off the cooperative thread pool and enforces `timeout`, since a hung
    /// whisper-cli or ffmpeg would otherwise wedge the pipeline (and one of its
    /// threads) forever.
    static func run(_ executable: URL, _ args: [String], in directory: URL,
                    label: String, timeout: TimeInterval = 1800) async throws {
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

        let (stream, continuation) = AsyncStream<Void>.makeStream()
        // Set before run(): a process that exits immediately must not be able to
        // terminate before there is a handler to catch it.
        process.terminationHandler = { _ in
            continuation.yield(())
            continuation.finish()
        }
        try process.run()

        let finishedInTime = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return true }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        if !finishedInTime {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            throw Notes.Failure.commandFailed(label, -1, "timed out after \(Int(timeout))s")
        }

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
        for key in ["GEMINI_API_KEY", "GEMINI_MODEL", "GROQ_API_KEY", "GROQ_MODEL",
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
