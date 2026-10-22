import Foundation
import os

/// The outcome of a `speak` call.
public struct SpeakResult: Sendable {
    /// Audio the engine produced (path may not exist for in-place engines).
    public let url: URL
     /// Human label of the engine that actually ran (may differ from requested
     /// when a fallback occurred).
    public let engineName: String
     /// The engine the caller asked for.
    public let requestedMode: TTSMode
     /// True when the requested engine was unavailable and a fallback ran.
    public let fellBack: Bool
    /// True when a real audio file exists at `url` (false for in-place engines).
    public let hasAudioFile: Bool
    /// Set when the engine that ran sends the text to a remote service (the
    /// UI shows it; `nil` for every offline engine).
    public let privacyNotice: String?

        /// A short, UI-friendly status line (empty on the happy path).
    public var statusLine: String {
        guard fellBack else { return "" }
        return "“\(requestedMode.rawValue)” unavailable — fell back to \(engineName)."
        }
}

/// Engine-agnostic orchestration. Picks the engine, applies graceful fallback
/// (a chosen engine that's missing → built-in voice, warned once), and
/// (optionally) plays the result. Returns a `SpeakResult` describing what
/// actually ran so the UI can tell the user when a fallback happened.
///
/// Finding 2 / meta-fix: every path is resolved through the `env` injected with
/// the call (defaulting to the manager's configured root), so synthesis honors
/// the user's model folder instead of the static default.
@MainActor
public struct TTSManager {

    private let config: TTSConfigManager

        /// P1 of the review: the cache dir is reclaimed after each write so it
        /// can't grow without bound. Inject the limits, or disable via
        /// `pruneAfterWrite: false`.
    private let cacheLimits: CacheGuardian.Limits
    private let pruneAfterWrite: Bool

        /// Builds the engine for a mode. Injectable so the orchestration
        /// (selection, fallback, play/no-play contract) is unit-testable
        /// without a real Piper/Kokoro/edge-tts installation.
    public typealias EngineFactory =
        @MainActor (TTSMode, String?, VoiceBridgeEnvironment) -> any TTSBackend
    private let engineFactory: EngineFactory

    /// The `cacheLimits` / `pruneAfterWrite` args default to a sensible "keep
    /// ~1k files / 2 GiB / 30 days" policy, so existing `TTSManager(config:)`
    /// call sites keep working unchanged.
    public init(config: TTSConfigManager,
                cacheLimits: CacheGuardian.Limits = .init(),
                pruneAfterWrite: Bool = true,
                engineFactory: EngineFactory? = nil) {
        self.config = config
        self.cacheLimits = cacheLimits
        self.pruneAfterWrite = pruneAfterWrite
        self.engineFactory = engineFactory ?? TTSManager.defaultEngineFactory
            }

           /// Speaks `text` using `mode` (defaults to the UI selection). Falls
           /// back to the built-in voice if the chosen engine is unavailable.
            /// When `play` is true, file-producing engines play via AVAudioPlayer
             /// and in-place engines via the system audio device.
      @discardableResult
    public func speak(_ text: String,
                      mode: TTSMode? = nil,
                      voice: String? = nil,
                      play: Bool = true,
                      fallingBack: Bool = true) async throws -> SpeakResult {
        let mode = mode ?? config.selectedMode
        let resolvedVoice = voice ?? config.selectedModelFile
        let env = config.environment()

        var engine = engineFactory(mode, resolvedVoice, env)
        var fellBack = false

               // Graceful degradation: chosen engine missing → built-in voice.
        if !engine.isAvailable() && fallingBack {
             let fallback = engineFactory(.system, nil, env)
            if fallback.isAvailable() {
            let note = "“\(mode.rawValue)” unavailable — falling back to \(fallback.displayName)."
                 VBLog.tts.warning("\(note)")
                 engine = fallback
                 fellBack = true
                 }
             }

        guard engine.isAvailable() else {
             throw VoiceError.engineUnavailable(engine: mode.rawValue,
                                                reason: "runtime not installed")
              }

             // Cache slot for file-producing engines (AVSpeech ignores this).

             // Privacy: if the engine that actually runs is network-bound
             // (edge-tts), tell the user their text is transiting Microsoft
             // servers. This is the P1 "loudly warn it's online" item.
            if engine.requiresNetwork {
                 VBLog.tts.warning("privacy: \"\(engine.displayName)\" is online — the input")
                 VBLog.tts.warning("text is sent to a remote service by edge-tts, not kept on-device;")
                 VBLog.tts.warning("switch to a local engine (Piper/Kokoro/System) for offline TTS.")
                 }
        // In-place engines (AVSpeech) *speak while synthesizing* - there is no
        // file to produce. Asking for synthesis without playback would still
        // make noise, so it is skipped entirely: `play: false` means "don't
        // speak", not "speak quietly".
        if !engine.producesAudioFile && !play {
            VBLog.tts.info("skipping in-place synthesis (\(engine.displayName)): playback not requested")
            return SpeakResult(url: env.cacheDir.appendingPathComponent("(in-place)"),
                               engineName: engine.displayName,
                               requestedMode: mode,
                               fellBack: fellBack,
                               hasAudioFile: false,
                               privacyNotice: Self.privacyNotice(for: engine))
        }

        // The cache dir may not exist yet (fresh install, user wiped it).
        // Every file-producing engine writes straight into it, so create it
        // first - otherwise the very first synthesis fails on a missing dir.
        try? FileManager.default.createDirectory(
            at: env.cacheDir, withIntermediateDirectories: true)

        let out = env.cacheDir
                     .appendingPathComponent(UUID().uuidString + "." + engine.preferredFileExtension)
        let url = try await engine.synthesize(text: text, voice: resolvedVoice, outputPath: out)
        VBLog.tts.info("wrote \(url.lastPathComponent) via \(engine.displayName)")
        if fellBack { VBLog.tts.notice("fell back to \(engine.displayName)") }

                // P1: reap the cache dir so it can't grow unbounded. The prune
               // walks the whole directory, so it runs OFF the main actor
               // (a big cache would otherwise stall the UI). The just-written
               // file is the newest, so it survives the pass.
        if pruneAfterWrite, engine.producesAudioFile {
            let dir = env.cacheDir
            let limits = cacheLimits
            Task.detached(priority: .utility) {
                let outcome = CacheGuardian().prune(directory: dir, limits: limits)
                if !outcome.isEmpty {
                    VBLog.tts.info("cache prune: removed \(outcome.removedCount) file(s), \(outcome.removedBytes) B")
                }
            }
                }

        let hasFile = engine.producesAudioFile
                     && FileManager.default.fileExists(atPath: url.path)

        guard play else {
            return SpeakResult(url: url, engineName: engine.displayName,
                               requestedMode: mode, fellBack: fellBack,
                               hasAudioFile: hasFile,
                               privacyNotice: Self.privacyNotice(for: engine))
             }

        if engine.producesAudioFile {
            if hasFile {
                try Playback.playAudio(url)
                   } else {
                VBLog.tts.warning("no audio file at \(url.path)")
                   }
              } else {
              // In-place (AVSpeech): `synthesize` already spoke the utterance
              // and resolved only when it finished, so there is nothing left
              // to do here (no run-loop spin, no estimated duration).
            VBLog.tts.info("spoken in-place via \(engine.displayName)")
              }
        return SpeakResult(url: url, engineName: engine.displayName,
                           requestedMode: mode, fellBack: fellBack,
                           hasAudioFile: hasFile,
                           privacyNotice: Self.privacyNotice(for: engine))
        }

           /// The user-facing notice for an engine that works online.
    private static func privacyNotice(for engine: any TTSBackend) -> String? {
        guard engine.requiresNetwork else { return nil }
        return "“\(engine.displayName)” is online: the text was sent to a remote service."
        }

           // The production engine factory. Paths come from `env` (the
           // configured root), never a static.
    public static let defaultEngineFactory: EngineFactory = { mode, voice, env in
        switch mode {
        case .system:
            return SystemVoiceBackend()
        case .piper:
              // A voice that looks like a path is used as a directory hint
             // (the caller pointed at a specific folder); otherwise the voice
             // lives in the configured root's `piper/voice` directory.
             let dir = (voice?.contains("/") == true)
                        ? URL(fileURLWithPath: voice ?? "")
                        : env.paths.piperVoiceDir
             let raw = ProcessInfo.processInfo.environment["VOICEBRIDGE_PIPER"]
             return PiperBackend(modelDirectory: dir,
                               binaryLocator: env.binaryLocator,
                              binaryOverride: raw)
        case .kokoro:
              // Pass the voice as a Kokoro *voice name* (e.g. af_bella); a path we
              // received is ignored by KokoroBackend, which uses af_bella by default
              // and auto-downloads its model to the HuggingFace cache on first use.
            let raw = ProcessInfo.processInfo.environment["VOICEBRIDGE_KOKORO"]
            return KokoroBackend(voice: voice,
                              cacheDirectory: env.cacheDir,
                            binaryOverride: raw,
                            binaryLocator: env.binaryLocator)
        case .edgeTTS:
            let raw = ProcessInfo.processInfo.environment["VOICEBRIDGE_EDGE_TTS"]
            return EdgeTTSBackend(modelDirectory: env.paths.root,
                               binaryLocator: env.binaryLocator,
                              binaryOverride: raw)
        case .fishAudio:
            // Only available when a server is configured; otherwise the
            // manager falls back to the built-in voice (and says so).
            if let configured = FishAudioBackend.fromEnvironment() {
                return configured
                }
            return FishAudioBackend(baseURL: URL(string: "http://127.0.0.1:8000")!,
                                    isConfigured: false)
           }
     }
}
