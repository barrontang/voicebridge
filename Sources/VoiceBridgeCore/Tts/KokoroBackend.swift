import Foundation

/// Kokoro-82M local TTS. ~80M params, excellent quality; the canonical runtime
/// is Python (Kokoro-PyTorch exported to ONNX), so this backend shells out to
/// an installed `kokoro` entry point. No mature Apple-native (pure Swift)
/// runtime exists yet — hence the process-based approach. The `.onnx` +
/// `config.json` pair lives under `<root>/tts/kokoro/`.
public final class KokoroBackend: TTSBackend, @unchecked Sendable {

    private let binary: String
    private let modelDirectory: URL

    public init(modelDirectory: URL = ModelPaths.kokoroDir, binaryOverride: String? = nil) {
        self.modelDirectory = modelDirectory
        self.binary = binaryOverride
               ?? ProcessInfo.processInfo.environment["VOICEBRIDGE_KOKORO"]
               ?? "kokoro"
     }

    public var displayName: String { "Kokoro-82M" }

      /// Voice is the `.onnx` base name (without extension) or a directory; the
        /// engine pairs `voice.onnx` + `voice/config.json`.
    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: binary)
               || Shell.pathLookup("kokoro") != nil
        }

    public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
        let voiceName = voice ?? "kokoro-en"
        let args = [binary,
                    "--text", text,
                        "--voice", "\(voiceName).onnx",
                        "--output", outputPath.path]
        // NOTE: exact flags depend on the kokoro CLI build you installed.
        try Pipeline.runWithStdin(input: text, at: args,
                                   workingDirectory: modelDirectory.path)
        return outputPath
        }
}
