import Foundation

/// Which speech-to-text engine the app should use.
///
/// This exists so the push-to-talk path and the live path make the *same*
/// decision. Both used to hardcode `WhisperCliBackend`, which meant a new
/// engine had to be wired in two places and could silently differ between
/// them.
public enum SttEngineKind: String, CaseIterable, Codable, Sendable {
    /// whisper.cpp, one process per transcription.
    case whisperCLI
    /// whisper.cpp, kept resident behind its HTTP server.
    case whisperServer
    /// Qwen3-ASR on llama.cpp, kept resident behind `llama-server`.
    case qwen3

    public var displayName: String {
        switch self {
        case .whisperCLI: return "whisper.cpp · per-request process"
        case .whisperServer: return "whisper.cpp server · resident"
        case .qwen3: return "Qwen3-ASR · resident, 30 languages + dialects"
        }
    }

    /// True when the audio provably never leaves this Mac.
    ///
    /// Qwen3-ASR is a hard yes: `QwenAsrServer` binds 127.0.0.1 and there is no
    /// setting that can point it elsewhere. whisper.cpp is a yes too (it is a
    /// local binary). The whisper *server* is "cannot prove" rather than "no":
    /// its URL comes from the environment and may name another machine, so a
    /// caller that cares must ask the user.
    public var isProvablyLocal: Bool {
        switch self {
        case .whisperCLI, .qwen3: return true
        case .whisperServer: return false
        }
    }
}

/// The persisted STT choice, and the factory that turns it into a backend.
public struct SttEngineSettings: Sendable, Equatable {

    public var kind: SttEngineKind
    /// The model used for the fast path: every live window, and the whole
    /// transcription when `finalTier` is nil.
    public var qwenTier: QwenAsrTier
    /// The model used for a committed utterance, when it should differ from
    /// the fast one. `nil` = one model for everything.
    public var qwenFinalTier: QwenAsrTier?

    public init(
        kind: SttEngineKind = .whisperCLI,
        qwenTier: QwenAsrTier = .fast,
        qwenFinalTier: QwenAsrTier? = nil
    ) {
        self.kind = kind
        self.qwenTier = qwenTier
        self.qwenFinalTier = qwenFinalTier
    }

    // MARK: - Persistence

    public enum Keys {
        public static let kind = "stt.engine"
        public static let qwenTier = "stt.qwen.tier"
        /// The literal `"none"` means "same model as the fast path".
        public static let qwenFinalTier = "stt.qwen.finalTier"
    }

    public static func load(from defaults: UserDefaults = .standard) -> SttEngineSettings {
        let kind =
            defaults.string(forKey: Keys.kind).flatMap(SttEngineKind.init(rawValue:)) ?? .whisperCLI
        let tier =
            defaults.string(forKey: Keys.qwenTier).flatMap(QwenAsrTier.init(rawValue:)) ?? .fast
        let finalRaw = defaults.string(forKey: Keys.qwenFinalTier)
        let final = finalRaw.flatMap(QwenAsrTier.init(rawValue:))
        return SttEngineSettings(kind: kind, qwenTier: tier, qwenFinalTier: final)
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(kind.rawValue, forKey: Keys.kind)
        defaults.set(qwenTier.rawValue, forKey: Keys.qwenTier)
        defaults.set(qwenFinalTier?.rawValue, forKey: Keys.qwenFinalTier)
    }

    // MARK: - Backend

    /// Build the file-level backend this configuration describes.
    ///
    /// `qwenServer` may be nil (the user picked a whisper engine, or the app
    /// has no server yet); asking for Qwen3 without one is a programming error
    /// and throws rather than silently falling back — a silent fallback would
    /// transcribe with a model the user did not choose.
    ///
    /// `tier` overrides the configured fast tier, which is how the live path
    /// asks for the accurate model on a final pass.
    public func makeBackend(
        modelDirectory: URL,
        whisperServerURL: URL? = nil,
        qwenServer: QwenAsrServer?,
        tier: QwenAsrTier? = nil
    ) async throws -> any WhisperBackend {
        switch kind {
        case .whisperCLI:
            return WhisperCliBackend(modelDirectory: modelDirectory)
        case .whisperServer:
            guard let whisperServerURL else {
                throw VoiceError.engineUnavailable(
                    engine: "whisper-server",
                    reason: "No server URL is configured (VOICEBRIDGE_WHISPER_SERVER).")
            }
            return WhisperServerBackend(baseURL: whisperServerURL)
        case .qwen3:
            guard let qwenServer else {
                throw VoiceError.engineUnavailable(
                    engine: "Qwen3-ASR", reason: "The llama-server manager is not available.")
            }
            let chosen = tier ?? qwenTier
            let url = try await qwenServer.baseURL(for: chosen)
            return QwenAsrBackend(baseURL: url, tier: chosen)
        }
    }

    /// Which tier the commit/final pass should use (the fast one when the user
    /// did not ask for two tiers).
    public var finalTierOrFast: QwenAsrTier { qwenFinalTier ?? qwenTier }

    /// True when a final pass should run on a different model than partials.
    public var usesTwoTiers: Bool {
        kind == .qwen3 && qwenFinalTier != nil && qwenFinalTier != qwenTier
    }
}
