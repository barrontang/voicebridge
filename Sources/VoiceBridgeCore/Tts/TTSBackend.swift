import Foundation

/// The pluggable TTS contract. Each engine produces an audio artifact for the
/// caller to play. `synthesize` is async because the real backends shell out to
/// a child process that can take hundreds of milliseconds / seconds.
public protocol TTSBackend: Sendable {
        /// Synthesize `text` into local audio, or (for in-place engines like
        /// AVSpeech) speak directly to the device. Resolves to a path that may
        /// or may not exist on disk — see `producesAudioFile`.
        ///
        /// `voice` is engine-specific: a Piper `.onnx` filename, a Kokoro model
        /// name, an edge-tts voice name, or an AVSpeechSynthesisVoice name.
    func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL

        /// True when the engine wrote a real audio file at the returned URL.
          /// False for engines that "speak in place" to the system audio device
          /// (AVSpeech) — the orchestrator skips the file-playback step for these.
    var producesAudioFile: Bool { get }

          /// True when the engine's runtime/dependencies are present on the host.
    func isAvailable() -> Bool
           /// Human label shown in the UI picker.
    var displayName: String { get }
}

public extension TTSBackend {
        /// File-producing engines (piper / kokoro / edge-tts) are the default.
        /// In-place engines override this to `false`.
    var producesAudioFile: Bool { true }
}
