import Foundation

/// Kokoro-82M TTS via the Python `kokoro` CLI.
///
/// The `kokoro` entry point is a Python console script (shipped with the
/// `kokoro` pip package; on this machine it lives in the conda base env and is
/// on PATH). It auto-downloads its 82M model (`hexgrad/Kokoro-82M`) into the
/// HuggingFace cache on first use, so a real voice lives *there*, not in our
/// own models dir. Pass a **voice name** (e.g. `af_bella`), not a path.
///
/// First import is slow (~15–60s: it loads onnxruntime), so everything funnels
/// through `Pipeline.runWithStdin`, which drains both pipes and honors a timeout
/// (120s here — enough for the first-run download + load).
///
/// NOTE on stdin: kokoro's CLI reads text from stdin by default. Its `-i`
/// flag expects a *real* file path, so we deliberately do NOT pass `-i -`
/// (kokoro would try to open a file literally named `-`); we simply omit it
/// and pipe the text via stdin.
public struct KokoroBackend: TTSBackend {
     public let displayName = "Kokoro-82M (local)"
   public let producesAudioFile = true

      /// Voice name to use by default when the caller doesn't specify one.
   private let defaultVoice: String
     /// Absolute path to a real `kokoro` executable (resolved from PATH / env).
   private let binaryPath: String

    public init(voice: String? = nil, binaryOverride: String? = nil) {
        let raw = binaryOverride
                    ?? ProcessInfo.processInfo.environment["VOICEBRIDGE_KOKORO"] ?? "kokoro"
        self.binaryPath = Shell.resolve(raw)
        self.defaultVoice = voice
                 ?? ProcessInfo.processInfo.environment["VOICEBRIDGE_KOKORO_VOICE"]
                 ?? KokoroBackend.fallbackVoice
        }

       /// A well-known English voice that ships with `kokoro`.
    static let fallbackVoice = "af_bella"

           // MARK: - TTSBackend

  public func isAvailable() -> Bool {
         // The binary must resolve to a *real* file that exists (installed on
         // PATH or via VOICEBRIDGE_KOKORO). We do NOT import kokoro here — that
         // would take 15–60s just to load onnxruntime; the first real call will
         // download the model to the HF cache and load it.
        FileManager.default.fileExists(atPath: binaryPath)
       }

@discardableResult
   public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
        let resolved = ModelPaths.cacheDir
                             .appendingPathComponent("kokoro-\(UUID().uuidString).wav")
        _ = try await Pipeline.runWithStdin(
            input: text,
            at: buildArgs(voice: voice, output: resolved),
            timeout: 120)
        if FileManager.default.fileExists(atPath: resolved.path) {
             return resolved
           }
         // Fall back to the caller's path (the engine may have written its own).
        return outputPath
      }

            // MARK: - argument construction

  private func buildArgs(voice: String?, output: URL) -> [String] {
        var argv = [binaryPath]
            // Kokoro takes a *voice name*, not a directory. A caller-supplied
           // path is meaningless to kokoro, so use the default voice instead.
        let chosenVoice = (voice?.contains("/") == false ? voice : nil)
                              ?? defaultVoice
        argv.append("-m"); argv.append(chosenVoice)
        let out = ProcessInfo.processInfo.environment["KOKORO_WAV_OUT"]
                  ?? output.path
        argv.append("-o"); argv.append(out)
            // Do NOT append `-i -`: kokoro's -i expects a real file path; it
           // reads text from stdin by default when no -t/-i is given.
         // Language is inferred from the voice, so we don't pass -l.
        return argv
        }
}
