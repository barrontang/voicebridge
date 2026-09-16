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

     public init(config: TTSConfigManager) {
        self.config = config
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

        var engine = makeEngine(mode, voice: resolvedVoice, env: env)
        var fellBack = false

               // Graceful degradation: chosen engine missing → built-in voice.
        if !engine.isAvailable() && fallingBack {
             let fallback = makeEngine(.system, voice: nil, env: env)
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
        let out = env.cacheDir
                     .appendingPathComponent(UUID().uuidString + ".wav")
        let url = try await engine.synthesize(text: text, voice: resolvedVoice, outputPath: out)
        VBLog.tts.info("wrote \(url.lastPathComponent) via \(engine.displayName)")
        if fellBack { VBLog.tts.notice("fell back to \(engine.displayName)") }

        guard play else {
            return SpeakResult(url: url, engineName: engine.displayName,
                               requestedMode: mode, fellBack: fellBack)
             }

        if engine.producesAudioFile {
            if FileManager.default.fileExists(atPath: url.path) {
                try Playback.playWAV(url)
                   } else {
                VBLog.tts.warning("no audio file at \(url.path)")
                   }
              } else {
              // In-place (AVSpeech): keep the main run loop busy so the utterance
              // actually plays before a CLI process would otherwise exit.
            Playback.spinMainRunLoop(for: TTSManager.estimatedSeconds(text))
            VBLog.tts.info("spoken in-place via \(engine.displayName)")
              }
        return SpeakResult(url: url, engineName: engine.displayName,
                           requestedMode: mode, fellBack: fellBack)
        }

           // Rough speaking-time estimate (~2.5 words/sec) to size the runloop spin.
    private static func estimatedSeconds(_ text: String) -> Double {
        let words = text.split { $0 == " " || $0 == "\n" }.count
        return max(1.5, Double(words) / 2.5 + 0.75)
         }

           // Build the engine for a mode *here* (on the main actor) so it can read
           // `@MainActor` config without a stored closure crossing isolation. Paths
          // come from `env` (the configured root), never a static.
    private func makeEngine(_ mode: TTSMode, voice: String?, env: VoiceBridgeEnvironment)
        -> TTSBackend {
        switch mode {
        case .system:
            return SystemVoiceBackend()
        case .piper:
             let dir = (voice?.contains("/") == true)
                       ? URL(fileURLWithPath: voice!)
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
           }
     }
}
