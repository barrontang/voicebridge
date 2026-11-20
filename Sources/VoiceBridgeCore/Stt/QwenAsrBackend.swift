import Foundation

/// The two open-weight Qwen3-ASR checkpoints we ship.
///
/// `fast` is the live/partial workhorse (small, ~0.8 GB, ~2 ms per second of
/// audio on an M4 Pro). `accurate` costs about twice the latency and ~2.6 GB
/// of memory, and is what the final pass of an utterance should use.
public enum QwenAsrTier: String, CaseIterable, Codable, Sendable {
    case fast = "0.6b"
    case accurate = "1.7b"

    /// What the picker shows.
    public var displayName: String {
        switch self {
        case .fast: return "Qwen3-ASR 0.6B · fastest"
        case .accurate: return "Qwen3-ASR 1.7B · most accurate"
        }
    }

    /// Short label for a one-line status ("Recognized · **Qwen3-ASR 0.6B**").
    public var shortLabel: String {
        switch self {
        case .fast: return "Qwen3-ASR 0.6B"
        case .accurate: return "Qwen3-ASR 1.7B"
        }
    }

    /// The GGUF weights file name inside `ModelPaths.qwen3Dir`.
    public var modelFileName: String {
        switch self {
        case .fast: return "Qwen3-ASR-0.6B-Q8_0.gguf"
        case .accurate: return "Qwen3-ASR-1.7B-Q8_0.gguf"
        }
    }

    /// The audio projector that must be loaded *with* the weights. Without it
    /// llama.cpp can read the text model but has no way to turn audio into
    /// tokens, and every request fails.
    public var mmprojFileName: String {
        switch self {
        case .fast: return "mmproj-Qwen3-ASR-0.6B-Q8_0.gguf"
        case .accurate: return "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"
        }
    }
}

/// Speech-to-text through a local `llama-server` running Qwen3-ASR.
///
/// Why a server instead of a per-request process: the model is ~1–3 GB and
/// takes seconds to load. A process per transcription would pay that on every
/// 1.2 s live window. `QwenAsrServer` keeps it resident and this type just
/// posts audio to it, exactly like `WhisperServerBackend` does for
/// whisper.cpp.
///
/// The wire format is OpenAI's `/v1/audio/transcriptions`, which llama.cpp
/// implements for audio models. The response is *not* OpenAI's shape though —
/// see `parseResponse`.
public final class QwenAsrBackend: WhisperBackend, @unchecked Sendable {

    /// Where the server answers.
    public let baseURL: URL
    public let tier: QwenAsrTier
    /// How long one request may take. A 20-minute file on a slow Mac is still
    /// far under this; the ceiling exists so a wedged server cannot hang the
    /// app forever.
    private let timeout: TimeInterval

    public init(baseURL: URL, tier: QwenAsrTier, timeout: TimeInterval = 300) {
        self.baseURL = baseURL
        self.tier = tier
        self.timeout = timeout
    }

    /// The path llama.cpp serves transcriptions on.
    static let transcriptionsPath = "v1/audio/transcriptions"

    public func transcribe(
        audio: URL,
        language: String?,
        model: SttModel,
        useTimestamps: Bool
    ) async throws -> Transcription {
        try Task.checkCancellation()

        let started = Date()
        let data = try Data(contentsOf: audio)
        let boundary = "voicebridge-\(UUID().uuidString)"
        let body = try Self.multipartBody(
            boundary: boundary, filename: audio.lastPathComponent, audio: data)

        var request = URLRequest(url: baseURL.appendingPathComponent(Self.transcriptionsPath))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceError.processFailed(
                component: "qwen3-asr",
                status: Int32(http.statusCode),
                stderr: String(data: responseData, encoding: .utf8) ?? "")
        }

        // An empty transcript is normal: silence produces no text, and the
        // live path treats that as "nothing said in this window" rather than
        // a failure (a thrown error would bump the failure counter every
        // time the user pauses).
        let parsed = Self.parseResponse(responseData)
        let elapsed = Date().timeIntervalSince(started)

        return Transcription(
            text: parsed.text,
            language: parsed.language ?? language ?? "auto",
            // No whisper model produced this, so the field stays empty and
            // `engineLabel` is what the UI shows. Passing the caller's
            // `model` through would claim a whisper checkpoint ran.
            model: nil,
            durationSeconds: 0,
            realtimeFactor: 0,
            segments: [],
            engineLabel: tier.shortLabel,
            wallClockSeconds: elapsed)
    }

    // MARK: - Wire format

    /// What one transcription response means.
    public struct Reply: Sendable, Equatable {
        /// The transcript with Qwen's `language X<asr_text>` preamble removed.
        public let text: String
        /// The language Qwen detected ("Chinese", "English", …), lower-cased.
        public let language: String?

        public init(text: String, language: String?) {
            self.text = text
            self.language = language
        }
    }

    /// Parse llama.cpp's transcription response.
    ///
    /// The body looks like:
    ///
    ///     {"type":"transcript.text.done",
    ///      "text":"language Chinese<asr_text>今天下午三点…","usage":{…}}
    ///
    /// Two things are worth knowing. First, the model always starts by
    /// *naming the language* and then emits a literal `<asr_text>` separator —
    /// that preamble is part of `text` and must be stripped, or every
    /// transcript in the UI begins with "language Chinese". Second, the
    /// language it names is the one piece of metadata we get for free, so we
    /// keep it rather than forcing the caller to run a second detection pass.
    public static func parseResponse(_ data: Data) -> Reply {
        let text = extractText(data)
        return splitPreamble(text)
    }

    /// Pull `text` out of the JSON, tolerating the SSE-wrapped form too.
    static func extractText(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = object["text"] as? String
        {
            return text
        }
        // Streaming responses arrive as `data: {...}` lines; the last `done`
        // event carries the full text.
        let raw = String(decoding: data, as: UTF8.self)
        var latest = ""
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let chunk = payload.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: chunk) as? [String: Any]
            else { continue }
            if let text = event["text"] as? String, !text.isEmpty { latest = text }
        }
        return latest
    }

    /// Split `language Chinese<asr_text>今天…` into its two halves.
    ///
    /// A response without the separator is passed through untouched — a future
    /// llama.cpp may stop emitting it, and dropping text we do not understand
    /// would be worse than showing a stray prefix.
    public static func splitPreamble(_ raw: String) -> Reply {
        let marker = "<asr_text>"
        guard let range = raw.range(of: marker) else {
            return Reply(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), language: nil)
        }
        let head = raw[raw.startIndex..<range.lowerBound]
        let body = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)

        var language: String? =
            head
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let named = language, named.hasPrefix("language") {
            language = String(named.dropFirst("language".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // "none" is what Qwen writes for silence; it is not a language.
        if language == "none" || language?.isEmpty == true { language = nil }
        return Reply(text: body, language: language)
    }

    /// Build the multipart body llama.cpp expects.
    static func multipartBody(boundary: String, filename: String, audio: Data) throws -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"model\"\r\n\r\n".utf8))
        body.append(Data("qwen3-asr\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8)
        )
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
