import Foundation

/// Resolves the on-disk layout of model files *relative to a single root*.
///
/// This used to be an `enum` of **static, global** properties (`root`,
/// `whisperDir`, `piperVoiceDir`, …) that every caller read directly. That was
/// the root cause of Findings 1 & 2: when a user picked a custom model folder,
/// `configureRoot` updated the *manager's* root but the statics never changed, so
/// TTS respected the override while STT kept reading the global default — a
/// silent, user-visible inconsistency.
///
/// It is now a **value type** carrying an explicit `root`. Callers resolve
/// subpaths off *their injected* `ModelPaths`, so the chosen root is the single
/// source of truth and "half my models disappeared on a custom folder" is a
/// type-level impossibility. The static-style global is gone (except the
/// `fromEnvironment` factory, which is the one legitimately-global read).
public struct ModelPaths: Sendable, Equatable {

      /// The model root that every subpath resolves against.
    public let root: URL

    public init(root: URL) { self.root = root.appendingIsDirectory() }

      /// Subdir holding whisper-cpp ggml files.
    public var whisperDir: URL { root.appendingPathComponent("whisper", isDirectory: true) }

      /// Subdir holding Piper voice `.onnx` files.
    public var piperVoiceDir: URL {
        root
          .appendingPathComponent("piper", isDirectory: true)
          .appendingPathComponent("voice", isDirectory: true)
     }

     /// Subdir holding Kokoro `.onnx` files.
    public var kokoroDir: URL { root.appendingPathComponent("kokoro", isDirectory: true) }

      /// Scratch dir for generated WAV/MP3 output.
    public var cacheDir: URL { root.appendingPathComponent("cache", isDirectory: true) }

      /// The one legitimately-global read: the default root.
      ///
      /// `~/.voicebridge/models/tts`, overridable via the
      /// `VOICEBRIDGE_MODELS_MAP` environment variable (CI / non-sandboxed dev).
      /// `nonisolated` so backends running off the main actor can build one without
      /// a stored reference.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment) -> ModelPaths {
        if let e = env["VOICEBRIDGE_MODELS_MAP"] {
            return ModelPaths(root: URL(fileURLWithPath: e))
        }
        return ModelPaths(root: FileManager.default.homeDirectoryForCurrentUser
                              .appendingPathComponent(".voicebridge", isDirectory: true)
                              .appendingPathComponent("models", isDirectory: true)
                              .appendingPathComponent("tts", isDirectory: true))
     }

      /// Convenience: a layout rooted at an arbitrary `root` (its `tts` layer).
    public static func make(_ root: URL) -> ModelPaths {
        ModelPaths(root: root)
   }
}
