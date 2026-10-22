import Foundation

/// **Fish Audio Drama 3** — a 35B MoE text-to-speech model served over HTTP.
///
/// Drama 3 is too large to run on a GPU-less Mac as-is, but two servers speak
/// its API:
///
///   * **local MLX** — the 4-bit Apple Silicon conversion, served by
///     `mlx-audio` (see `scripts/start-drama3-mlx.sh`). This is the default
///     when the checkpoint has been downloaded.
///   * **remote GPU** — the full FP8 model behind SGLang-Omni or vLLM-Omni.
///
/// Either way VoiceBridge talks to an OpenAI-compatible endpoint:
///
///     POST {base}/v1/audio/speech
///     { "input": "Hello", "model": …, "ref_audio": …, "ref_text": … }
///     → the audio (WAV) as the response body
///
/// What Drama 3 adds over the other engines: **multi-speaker** (up to 16
/// characters via `<|speaker:0|>` … `<|speaker:15|>` tags in the text),
/// **voice cloning** from a reference clip, and long-form chunking.
///
/// Configuration (environment):
///   * `VOICEBRIDGE_FISH_TTS` — the base URL of the server. When unset, the
///     local MLX server (`http://127.0.0.1:8000`) is used if its checkpoint
///     is installed.
///   * `VOICEBRIDGE_FISH_MODEL` — the model name or path sent to the server
///     (defaults to the local MLX checkpoint, or nothing for a remote one).
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

    /// The HF repo of the 4-bit Apple Silicon conversion.
    public static let localModelRepo = "mlx-community/fish-audio-drama-3-4bit"
    /// The directory `scripts/install-drama3-mlx.sh` downloads it into.
    public static let localDirectoryName = "fish-audio-drama-3-4bit"
    /// Where the local `mlx-audio` server listens by default.
    public static let defaultLocalURL = "http://127.0.0.1:8000"

    /// The server's base URL (without the `/v1/audio/speech` suffix).
    public let baseURL: URL
    /// The model name (or local path) the server should load.
    public let modelID: String?
    /// A reference clip for voice cloning (a local path or an URL).
    public let referencePath: String?
    /// The transcript of the reference clip.
    public let referenceText: String?
    /// An optional bearer token.
    private let apiKey: String?
    /// False when no server was configured (the engine then falls back).
    private let isConfigured: Bool
    /// How long a request may take (a 22 GB model is not instant).
    private let timeout: TimeInterval
    /// A cheap "is the local server up?" check, cached for a few seconds.
    private let probe = ServerProbe()

    public init(baseURL: URL,
                modelID: String? = nil,
                referencePath: String? = nil,
                referenceText: String? = nil,
                apiKey: String? = nil,
                timeout: TimeInterval = 300,
                isConfigured: Bool = true) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.referencePath = referencePath
        self.referenceText = referenceText
        self.apiKey = apiKey
        self.timeout = timeout
        self.isConfigured = isConfigured
    }

    /// The engine when no server is configured: it reports itself as
    /// unavailable, so the manager falls back to the built-in voice.
    public static func unconfigured() -> FishAudioBackend {
        FishAudioBackend(baseURL: URL(string: defaultLocalURL)
                            ?? URL(fileURLWithPath: "/"),
                          isConfigured: false)
    }

    /// The checkpoint directory the installer writes, under the model root.
    public static func localModelDirectory(root: URL) -> URL {
        root.appendingPathComponent(localDirectoryName, isDirectory: true)
    }

    /// The 22 GB of routed experts, give or take re-sharding.
    public static let minimumLocalModelBytes: Int64 = 18_000_000_000

    /// True when the 4-bit MLX checkpoint is fully installed.
    ///
    /// `config.json` alone is not enough: the hub downloads it first, so the
    /// engine would appear ready while the weights were still arriving. The
    /// safetensors are written under their final names only after each file
    /// completes, so their total size is an accurate readiness signal.
    public static func localModelExists(
        root: URL,
        minimumBytes: Int64 = minimumLocalModelBytes
    ) -> Bool {
        let dir = localModelDirectory(root: root)
        let manager = FileManager.default
        guard manager.fileExists(atPath: dir.appendingPathComponent("config.json").path),
              manager.fileExists(atPath: dir.appendingPathComponent("codec.safetensors").path)
        else { return false }

        let files = (try? manager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total: Int64 = 0
        for file in files
        where file.lastPathComponent.hasPrefix("model-")
            && file.pathExtension == "safetensors" {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total >= minimumBytes
    }

    /// The engine configured through the environment.
    ///
    /// With no explicit `VOICEBRIDGE_FISH_TTS`, a downloaded 4-bit MLX
    /// checkpoint selects the local server — that is what makes Drama 3 a
    /// normal engine in the app rather than a manual setup.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment,
        modelRoot: URL? = nil
    ) -> FishAudioBackend? {
        let modelID = env["VOICEBRIDGE_FISH_MODEL"].flatMap { $0.isEmpty ? nil : $0 }

        if let raw = env["VOICEBRIDGE_FISH_TTS"], !raw.isEmpty {
            let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            guard let url = URL(string: trimmed) else { return nil }
            // A local server still needs to be told which checkpoint to load
            // (`SpeechRequest.model` is required) — e.g. when the port moved
            // but the checkpoint stayed in the default folder.
            let localPath: String? = {
                guard let modelRoot,
                      ServerProbe.isLoopback(url.host ?? ""),
                      localModelExists(root: modelRoot) else { return nil }
                return localModelDirectory(root: modelRoot).path
            }()
            return FishAudioBackend(baseURL: url,
                                    modelID: modelID ?? localPath,
                                    referencePath: env["VOICEBRIDGE_FISH_REFERENCE"],
                                    referenceText: env["VOICEBRIDGE_FISH_REFERENCE_TEXT"],
                                    apiKey: env["VOICEBRIDGE_FISH_API_KEY"])
        }

        if let modelRoot, localModelExists(root: modelRoot) {
            let local = localModelDirectory(root: modelRoot)
            return FishAudioBackend(
                baseURL: URL(string: defaultLocalURL) ?? URL(fileURLWithPath: "/"),
                // A path, not a repo id: the server loads the checkpoint
                // straight from disk and never hits the network.
                modelID: modelID ?? local.path,
                referencePath: env["VOICEBRIDGE_FISH_REFERENCE"],
                referenceText: env["VOICEBRIDGE_FISH_REFERENCE_TEXT"],
                apiKey: env["VOICEBRIDGE_FISH_API_KEY"])
        }

        return nil
    }

    public var producesAudioFile: Bool { true }

    public var displayName: String {
        isLocal ? "Fish Audio (Drama 3, local MLX)" : "Fish Audio (Drama 3)"
    }

    /// True only when the server is on another machine. A local MLX server
    /// keeps the text on this Mac, so it is not an "online" engine in the
    /// privacy sense.
    public var requiresNetwork: Bool { !isLocal }

    /// The server writes a WAV.
    public var preferredFileExtension: String { "wav" }

    /// True when the configured server is on this Mac.
    public var isLocal: Bool {
        guard let host = baseURL.host else { return false }
        return ServerProbe.isLoopback(host)
    }

    /// Available when a server is configured *and*, for a local one, something
    /// is listening on its port. A remote failure is reported by the request.
    public func isAvailable() -> Bool {
        guard isConfigured else { return false }
        return probe.isReachable(baseURL)
    }

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
                                                modelID: modelID,
                                                referencePath: reference,
                                                referenceText: referenceText)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw VoiceError.engineUnavailable(
                engine: displayName,
                reason: Self.hint(for: error, baseURL: baseURL))
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw VoiceError.onlineServiceRejected(
                engine: "Fish Audio",
                reason: "the server answered HTTP \(http.statusCode)"
                    + (detail.isEmpty ? "" : ": " + String(detail.prefix(160))))
        }
        // A server can answer 200 with an error document (mlx-audio reports a
        // bad request that way once streaming has started). Never write that
        // to a .wav and hand it to the player.
        guard Self.looksLikeAudio(data) else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw VoiceError.onlineServiceRejected(
                engine: "Fish Audio",
                reason: "the server returned something that is not audio"
                    + (detail.isEmpty ? "." : ": " + detail))
        }

        try FileManager.default.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try data.write(to: outputPath, options: .atomic)
        return outputPath
    }

    /// A short, actionable line for a transport failure.
    static func hint(for error: URLError, baseURL: URL) -> String {
        let host = baseURL.host ?? "the server"
        let port = baseURL.port ?? (baseURL.scheme == "https" ? 443 : 80)
        let local = ServerProbe.isLoopback(host)
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
             .notConnectedToInternet, .timedOut:
            if local {
                return "nothing is listening on \(host):\(port) — start the local "
                    + "Drama 3 server with scripts/start-drama3-mlx.sh"
            }
            return "could not reach \(host):\(port)"
        default:
            return error.localizedDescription
        }
    }

    /// WAV, MP3, FLAC, Ogg or raw PCM — anything with a plausible header. An
    /// HTML or JSON error page is rejected.
    static func looksLikeAudio(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(4))
        if bytes.count >= 4 {
            if bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46 {
                return true // RIFF (WAV)
            }
            if bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
                return true // fLaC
            }
            if bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
                return true // OggS
            }
            if bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
                return true // MP3 (ID3)
            }
            if bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 {
                return true // MP3 frame
            }
        }
        return false
    }

    /// The JSON body.
    ///
    /// `input` is the OpenAI-compatible field; `text` is what the Drama 3
    /// examples use. `ref_audio`/`ref_text` are the `mlx-audio` spelling and
    /// `references` is SGLang's: each server ignores the other's key.
    static func requestBody(text: String,
                            modelID: String? = nil,
                            referencePath: String?,
                            referenceText: String?) throws -> Data {
        var payload: [String: Any] = [
            "input": text,
            "text": text,
            "response_format": "wav",
        ]
        if let modelID, !modelID.isEmpty {
            payload["model"] = modelID
        }
        if let referencePath, !referencePath.isEmpty {
            payload["ref_audio"] = referencePath
            var reference: [String: Any] = ["audio_path": referencePath]
            if let referenceText, !referenceText.isEmpty {
                payload["ref_text"] = referenceText
                reference["text"] = referenceText
            }
            payload["references"] = [reference]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
