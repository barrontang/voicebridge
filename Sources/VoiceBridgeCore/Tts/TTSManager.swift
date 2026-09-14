import Foundation

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

        var engine = makeEngine(mode, voice: resolvedVoice)
        var fellBack = false

               // Graceful degradation: chosen engine missing → built-in voice.
        if !engine.isAvailable() && fallingBack {
             let fallback = makeEngine(.system, voice: nil)
            if fallback.isAvailable() {
                let note = "“\(mode.rawValue)” unavailable — falling back to \(fallback.displayName)."
                print("[TTS] \(note)")
                engine = fallback
                fellBack = true
                 }
            }

        guard engine.isAvailable() else {
             throw VoiceError.engineUnavailable(engine: mode.rawValue,
                                                reason: "runtime not installed")
             }

           // Cache slot for file-producing engines (AVSpeech ignores this).
        let out = ModelPaths.cacheDir
                    .appendingPathComponent(UUID().uuidString + ".wav")
        let url = try await engine.synthesize(text: text, voice: resolvedVoice, outputPath: out)
        print("[TTS] wrote \(url.lastPathComponent) via \(engine.displayName)\(fellBack ? " (fallback)" : "")")

        guard play else {
            return SpeakResult(url: url, engineName: engine.displayName,
                               requestedMode: mode, fellBack: fellBack)
            }

        if engine.producesAudioFile {
            if FileManager.default.fileExists(atPath: url.path) {
                try Playback.playWAV(url)
                 } else {
                print("[TTS] no audio file at \(url.path)")
                 }
             } else {
             // In-place (AVSpeech): keep the main run loop busy so the utterance
             // actually plays before a CLI process would otherwise exit.
            Playback.spinMainRunLoop(for: TTSManager.estimatedSeconds(text))
            print("[TTS] spoken in-place via \(engine.displayName)")
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
          // `@MainActor` config without a stored closure crossing isolation.
    private func makeEngine(_ mode: TTSMode, voice: String?) -> TTSBackend {
        switch mode {
        case .system:
            return SystemVoiceBackend()
        case .piper:
            return PiperBackend(
                 modelDirectory: (voice?.contains("/") == true)
                      ? URL(fileURLWithPath: voice!)
                      : ModelPaths.piperVoiceDir,
                 binaryOverride: ProcessInfo.processInfo.environment["VOICEBRIDGE_PIPER"])
        case .kokoro:
            // Pass the voice as a Kokoro *voice name* (e.g. af_bella); a path we
            // received is ignored by KokoroBackend, which uses af_bella by default
            // and auto-downloads its model to the HuggingFace cache on first use.
            return KokoroBackend(
                 voice: voice,
                 binaryOverride: ProcessInfo.processInfo.environment["VOICEBRIDGE_KOKORO"])
        case .edgeTTS:
            return EdgeTTSBackend(
                 binaryOverride: ProcessInfo.processInfo.environment["VOICEBRIDGE_EDGE_TTS"])
         }
    }
}
