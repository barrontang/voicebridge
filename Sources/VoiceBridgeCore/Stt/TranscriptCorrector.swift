import Foundation

/// A post-processor that fixes mis-heard words in a finished sentence.
///
/// The live path commits a sentence as soon as whisper returns it, which is
/// what makes captions feel instant — but whisper has no memory: "their" for
/// "there", a wrong homophone, a split or merged word. A corrector sees the
/// preceding sentences, so it can fix exactly those words without touching the
/// rest of the transcript.
///
/// Contract: return the corrected sentence, or `nil` when there is nothing to
/// change. The caller re-checks the result (`CorrectionPolicy`) and applies it
/// word-by-word; a corrector is never trusted to rewrite a sentence.
public protocol TranscriptCorrector: Sendable {
    func correct(sentence: String, context: [String]) async throws -> String?
}

/// The reference corrector: a local Ollama model, on loopback.
///
/// Uses Ollama's **native** `/api/chat` rather than the OpenAI-compatible
/// facade, because that is where `think: false` exists: `qwen3.5` is a
/// thinking model, and letting it reason before answering turned a 0.2 s
/// correction into one that did not finish inside a 4 s budget (and the
/// OpenAI-compatible endpoint ignored the flag and hung).
///
/// Text (never audio) goes to a model on this Mac. There is no remote default
/// and no API key: if Ollama is not running the call fails and the transcript
/// stays exactly as whisper wrote it.
public struct LocalLLMCorrector: TranscriptCorrector {

    public struct Configuration: Sendable {
        /// Ollama's root (not `/v1`). Loopback by design.
        public var baseURL: URL
        public var model: String
        /// A sentence is short; 4 s is generous and keeps a stalled model from
        /// delaying the next sentence's correction.
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:11434")
                ?? URL(fileURLWithPath: "/"),
            model: String = LocalLLMCorrector.defaultModel,
            timeout: TimeInterval = 6
        ) {
            self.baseURL = baseURL
            self.model = model
            self.timeout = timeout
        }
    }

    public static let defaultModel = "qwen3.5:4b"

    /// Kept as a constant so a test can assert the prompt, and so it is obvious
    /// what the local model is being asked to do.
    public static let systemPrompt = """
        You clean up speech-to-text output. You receive the previous sentences \
        as context, then the newest sentence. Fix only words the recognizer \
        clearly misheard (homophones, wrong characters, split or merged words) \
        using the context. Do not rephrase, translate, reorder, add or remove \
        information. Keep the same language, tone and punctuation style. If the \
        sentence is already correct, return it unchanged. Return only the \
        corrected sentence — no quotes, no explanation, no preamble.
        """

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = configuration.timeout
        config.timeoutIntervalForResource = configuration.timeout
        self.session = URLSession(configuration: config)
    }

    public init(model: String) {
        self.init(configuration: Configuration(model: model))
    }

    public func correct(sentence: String, context: [String]) async throws -> String? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var request = URLRequest(
            url: configuration.baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatRequest(
            model: configuration.model,
            stream: false,
            // The difference between 0.2 s and a timeout.
            think: false,
            options: .init(temperature: 0),
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: Self.userMessage(sentence: trimmed, context: context)),
            ])
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.parse(data)
    }

    /// The user turn: just enough context to resolve a homophone, never more
    /// (a long prompt slows a small model down and invites it to rewrite).
    static func userMessage(sentence: String, context: [String]) -> String {
        let previous = context.isEmpty ? "(none)" : context.joined(separator: "\n")
        return """
            Previous sentences:
            \(previous)

            Newest sentence:
            \(sentence)
            """
    }

    /// Pull `message.content` out of Ollama's native response.
    ///
    /// A thinking model can still wrap the answer in quotes or a code fence,
    /// which is stripped here.
    static func parse(_ data: Data) -> String? {
        struct Response: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
            let raw = decoded.message?.content
        else { return nil }
        let cleaned = stripWrapping(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func stripWrapping(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Drop the opening fence line and any closing fence.
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for quote in ["\"", "“", "”", "'"] {
            if s.hasPrefix(quote) && s.hasSuffix(quote) && s.count > 2 {
                s = String(s.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Options: Encodable { let temperature: Double }
        let model: String
        let stream: Bool
        let think: Bool
        let options: Options
        let messages: [Message]
    }
}
