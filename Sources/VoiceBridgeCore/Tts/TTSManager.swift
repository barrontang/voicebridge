import Foundation

/// Engine-agnostic orchestration. Picks the engine, applies graceful fallback
/// (Piper missing → built-in voice, warned once), and (optionally) plays the
/// result. Returns the produced audio URL so a caller can log/inspect it.
@MainActor
public struct TTSManager {

    private let config: TTSConfigManager

    public init(config: TTSConfigManager) {
        self.config = config
         }

         /// Speaks `text` using `mode` (defaults to the UI selection). Falls back
         /// to the built-in voice if the chosen engine is unavailable. When
         /// `play` is true, file-producing engines are played via AVAudioPlayer and
         /// in-place engines via a brief runloop spin.
    @discardableResult
    public func speak(_ text: String,
                      mode: TTSMode? = nil,
                      voice: String? = nil,
                      play: Bool = true,
                      fallingBack: Bool = true) async throws -> URL {
        let mode = mode ?? config.selectedMode
        let resolvedVoice = voice ?? config.selectedModelFile

        var engine = makeEngine(mode, voice: resolvedVoice)

              // Graceful degradation: chosen engine missing → built-in voice.
        if !engine.isAvailable() && fallingBack {
             let fallback = makeEngine(.system, voice: nil)
            if fallback.isAvailable() {
                print("[TTS] \(mode.rawValue) unavailable, falling back to built-in voice.")
                engine = fallback
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
        print("[TTS] wrote \(url.lastPathComponent) via \(engine.displayName)")

        guard play else { return url }

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
        return url
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
            return KokoroBackend(
                 modelDirectory: ModelPaths.kokoroDir,
                 binaryOverride: ProcessInfo.processInfo.environment["VOICEBRIDGE_KOKORO"])
        case .edgeTTS:
            return EdgeTTSBackend(
                 binaryOverride: ProcessInfo.processInfo.environment["VOICEBRIDGE_EDGE_TTS"])
        }
    }
}
