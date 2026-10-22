import Foundation

/// **Fish Audio Drama 3** — a 35B MoE text-to-speech model served over HTTP.
///
/// Drama 3 is far too large to run on a Mac (37 GB of weights, 3B active per
/// token, an NVIDIA GPU), so it is *served*: SGLang-Omni (or vLLM-Omni) keeps
/// the model resident and exposes an OpenAI-compatible endpoint:
///
///     sgl-omni serve --model-path fishaudio/drama-3 --port 8000
///
/// VoiceBridge talks to that endpoint:
///
///     POST {base}/v1/audio/speech
///     { "input": "Hello", "references": [ { "audio_path": …, "text": … } ] }
///     → the audio file (WAV) as the response body
///
/// What Drama 3 adds over the other engines: **multi-speaker** (up to 16
/// characters via `<|speaker:0|>` … `<|speaker:15|>` tags in the text),
/// **voice cloning** from a reference clip, and long-form chunking.
///
/// Configuration (environment):
///   * `VOICEBRIDGE_FISH_TTS` — the base URL of the server (e.g.
///     `http://127.0.0.1:8000`). The engine is only offered when this is set.
///   * `VOICEBRIDGE_FISH_REFERENCE` — a reference clip (path or URL) used for
///     voice cloning.
///   * `VOICEBRIDGE_FISH_REFERENCE_TEXT` — the transcript of that clip
///     (the server needs it to clone the voice).
///   * `VOICEBRIDGE_FISH_API_KEY` — bearer token, when the server wants one.
///
/// The engine is **online** from VoiceBridge's point of view: the text is
/// sent to an HTTP service, so it goes through the same "are you sure?" consent
/// as Edge TTS (see `TTSManager`).
public final class FishAudioBackend: TTSBackend, @unchecked Sendable {

    /// The server's base URL (without the `/v1/audio/speech` suffix).
    public let baseURL: URL
    /// A reference clip for voice cloning (a local path or an URL).
    public let referencePath: String?
    /// The transcript of the reference clip.
    public let referenceText: String?
    /// An optional bearer token.
    private let apiKey: String?
    /// False when no server was configured (the engine then falls back).
    private let isConfigured: Bool
    /// How long a request may take (a 35B model is not instant).
    private let timeout: TimeInterval

    public init(baseURL: URL,
                referencePath: String? = nil,
                referenceText: String? = nil,
                apiKey: String? = nil,
                timeout: TimeInterval = 300,
                isConfigured: Bool = true) {
        self.baseURL = baseURL
        self.referencePath = referencePath
        self.referenceText = referenceText
        self.apiKey = apiKey
        self.timeout = timeout
        self.isConfigured = isConfigured
    }

    /// The engine when no server is configured: it reports itself as
    /// unavailable, so the manager falls back to the built-in voice.
    public static func unconfigured() -> FishAudioBackend {
        FishAudioBackend(baseURL: URL(string: "http://127.0.0.1:8000")
                            ?? URL(fileURLWithPath: "/"),
                          isConfigured: false)
    }

    /// The engine configured through the environment (nil when there is no
    /// server to talk to).
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> FishAudioBackend? {
        guard let raw = env["VOICEBRIDGE_FISH_TTS"],
              !raw.isEmpty else { return nil }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard let url = URL(string: trimmed) else { return nil }
        return FishAudioBackend(baseURL: url,
                                referencePath: env["VOICEBRIDGE_FISH_REFERENCE"],
                                referenceText: env["VOICEBRIDGE_FISH_REFERENCE_TEXT"],
                                apiKey: env["VOICEBRIDGE_FISH_API_KEY"])
    }

    public var producesAudioFile: Bool { true }
    public var displayName: String { "Fish Audio (Drama 3)" }

    /// The text is sent to an HTTP service - it may be another machine.
    public var requiresNetwork: Bool { true }

    /// The server writes a WAV.
    public var preferredFileExtension: String { "wav" }

    /// Available when a server was configured. The request itself reports a
    /// server that is down (or unreachable) - a network round-trip per
    /// `isAvailable()` call would be wasteful.
    public func isAvailable() -> Bool { isConfigured }

    public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
        try Task.checkCancellation()

        // The voice slot carries the reference clip when one is configured
        // (the Settings picker has no file list for a served model). A local
        // path only works with a local server; a URL works with any server.
        let reference = referencePath
            ?? voice.flatMap { $0.contains("/") ? $0 : nil }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/audio/speech"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        request.timeoutInterval = timeout
        request.httpBody = try Self.requestBody(text: text,
                                                referencePath: reference,
                                                referenceText: referenceText)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw VoiceError.onlineServiceRejected(
                engine: "Fish Audio",
                reason: "the server answered HTTP \(http.statusCode)"
                    + (detail.isEmpty ? "" : ": " + String(detail.prefix(160))))
            }
        guard !data.isEmpty else {
            throw VoiceError.onlineServiceRejected(
                engine: "Fish Audio", reason: "the server returned no audio.")
            }

        try FileManager.default.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: outputPath, options: .atomic)
        return outputPath
    }

    /// The JSON body. `input` is the OpenAI-compatible field; `text` is what
    /// the Drama 3 examples use - sending both keeps it working either way.
    static func requestBody(text: String,
                             referencePath: String?,
                             referenceText: String?) throws -> Data {
        var payload: [String: Any] = [
            "input": text,
            "text": text,
            "response_format": "wav",
            ]
        if let referencePath, !referencePath.isEmpty {
            var reference: [String: Any] = ["audio_path": referencePath]
            if let referenceText, !referenceText.isEmpty {
                reference["text"] = referenceText
                }
            payload["references"] = [reference]
            }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
