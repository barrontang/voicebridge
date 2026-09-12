import Foundation

/// Nonisolated path root for models. Kept out of the `@MainActor`
/// `TTSConfigManager` so backends (which run off the main actor) can read it
/// freely.
public enum ModelPaths {

       /// Default model root: `~/.voicebridge/models/tts`, or the
         /// `VOICEBRIDGE_MODELS_MAP` override (useful for CI / non-sandboxed dev).
       ///
       /// NOTE: `default` is a reserved Swift keyword, so we expose `root`.
    public static var root: URL {
        if let e = ProcessInfo.processInfo.environment["VOICEBRIDGE_MODELS_MAP"] {
            return URL(fileURLWithPath: e).appendingIsDirectory()
             }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
                  .appendingPathComponent(".voicebridge", isDirectory: true)
                  .appendingPathComponent("models", isDirectory: true)
                  .appendingPathComponent("tts", isDirectory: true)
        }

        /// Subdir holding whisper-cpp ggml files.
    public static var whisperDir: URL { root.appendingPathComponent("whisper", isDirectory: true) }

        /// Subdir holding Piper voice `.onnx` files.
    public static var piperVoiceDir: URL { root
                  .appendingPathComponent("piper", isDirectory: true)
                  .appendingPathComponent("voice", isDirectory: true) }

        /// Subdir holding Kokoro `.onnx` files.
    public static var kokoroDir: URL { root.appendingPathComponent("kokoro", isDirectory: true) }

        /// Scratch dir for generated WAV/MP3 output.
    public static var cacheDir: URL { root.appendingPathComponent("cache", isDirectory: true) }
}
