import Foundation

/// Talks to a local `whisper.cpp` **server** instead of spawning a process
/// per transcription.
///
/// This is the interim step towards the in-process backend (Finding 12): the
/// server keeps the model resident in memory, so the live path does not pay a
/// process spawn (and a model load) every 1.2 seconds. It is still 100% local
/// — the server runs on the same machine, bound to 127.0.0.1.
///
///     whisper-server -m ~/.voicebridge/models/tts/whisper/ggml-large-v3-turbo.bin
///     # → http://127.0.0.1:8080
///
/// Enable it with `VOICEBRIDGE_WHISPER_SERVER=http://127.0.0.1:8080` (or pass
/// the URL explicitly). When it is not set, the CLI backend is used.
public final class WhisperServerBackend: WhisperBackend, @unchecked Sendable {

    /// The server's base URL.
    public let baseURL: URL
    /// The model to ask for (the server may host several).
    private let model: String?
    /// The language to force (nil = auto-detect).
    private let language: String?
    /// How long a request may take.
    private let timeout: TimeInterval

    public init(baseURL: URL,
                model: String? = nil,
                language: String? = nil,
                timeout: TimeInterval = 120) {
        self.baseURL = baseURL
        self.model = model
        self.language = language
        self.timeout = timeout
    }

    /// The server configured through the environment (nil when there is none).
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> WhisperServerBackend? {
        guard let raw = env["VOICEBRIDGE_WHISPER_SERVER"], !raw.isEmpty else { return nil }
        let url = raw.hasPrefix("http") ? raw : "http://\(raw)"
        guard let parsed = URL(string: url) else { return nil }
        return WhisperServerBackend(baseURL: parsed,
                                    model: env["VOICEBRIDGE_WHISPER_MODEL"],
                                    language: env["VOICEBRIDGE_WHISPER_LANG"])
    }

    /// The server is "available" when it answers. (A network round-trip per
    /// call would be wasteful, so availability means "configured".)
    public func isAvailable() -> Bool { true }

    public func transcribe(audio: URL,
                           language: String?,
                           model: SttModel,
                           useTimestamps: Bool) async throws -> Transcription {
        try Task.checkCancellation()

        let data = try Data(contentsOf: audio)
        let boundary = "voicebridge-\(UUID().uuidString)"
        let body = try Self.multipartBody(boundary: boundary,
                                          filename: audio.lastPathComponent,
                                          audio: data)

        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceError.processFailed(component: "whisper-server",
                                           status: Int32(http.statusCode),
                                           stderr: String(data: responseData, encoding: .utf8) ?? "")
            }

        let meta = WhisperTranscriptParser.parseJSON(responseData)
        let text = meta?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw VoiceError.processFailed(component: "whisper-server", status: -1,
                                           stderr: "The server returned no transcript.")
            }

        let requested = language ?? self.language
        return Transcription(
            text: text,
            language: requested ?? meta?.language ?? "auto",
            model: model,
            durationSeconds: meta?.durationSeconds ?? 0,
            realtimeFactor: 0,
            segments: meta?.segments ?? [])
    }

    /// Build the multipart body the server expects.
    static func multipartBody(boundary: String, filename: String, audio: Data) throws -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
