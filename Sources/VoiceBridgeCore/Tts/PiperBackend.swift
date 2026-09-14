import Foundation

/// Piper: a local, ONNX-based TTS engine (rhasspy/piper). Fully offline;
/// installs via `scripts/install-piper.sh` and voices live under
/// `<root>/piper/voice/<name>.onnx` + `<name>.onnx.json` (the config).
///
/// CLI shape: `printf '%s' "text" | piper -m model.onnx -f out.wav`
/// (`-m` model, `-f` output WAV, text on stdin; the `.onnx.json` sidecar is
/// auto-loaded for config).
public final class PiperBackend: TTSBackend, @unchecked Sendable {

    private let binary: String
    private let modelDirectory: URL

    public init(modelDirectory: URL, binaryOverride: String? = nil) {
        self.modelDirectory = modelDirectory
        let raw = binaryOverride
            ?? ProcessInfo.processInfo.environment["VOICEBRIDGE_PIPER"]
            ?? "piper"
        // Resolve to an absolute path: Process(executableURL:) needs an absolute
        // path, so passing the bare name "piper" would silently fail to launch.
        self.binary = Shell.resolve(raw)
    }

    public var displayName: String { "Piper \(modelDirectory.lastPathComponent)" }

    /// Available when its binary is present (override or on PATH).
    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: binary)
        || Shell.pathLookup("piper") != nil
    }

    public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
        // Resolve to a concrete .onnx path.
        let model: URL
        if let voice, voice.contains("/") {
            model = URL(fileURLWithPath: voice)
        } else {
            var v = voice ?? "en_US-lessac-medium"     // sensible default
            if !v.hasSuffix(".onnx") { v += ".onnx" }
            model = modelDirectory.appendingPathComponent(v)
        }

        guard FileManager.default.fileExists(atPath: model.path) else {
            throw VoiceError.modelMissing(model: model.lastPathComponent,
                                          directory: modelDirectory.path)
        }

        var args: [String] = [binary, "-m", model.path, "-f", outputPath.path]
        // Piper auto-loads the sidecar config if it lives next to the model.
        let config = model.deletingPathExtension().appendingPathExtension("onnx.json")
        if FileManager.default.fileExists(atPath: config.path) {
            args += ["-c", config.path]
        }

        // Pipe text on stdin; piper writes to out WAV and (possibly) warns on
        // stderr, which Pipeline drains.
        try Pipeline.runWithStdin(input: text, at: args,
                                   workingDirectory: modelDirectory.path,
                                   timeout: 120)

        guard FileManager.default.fileExists(atPath: outputPath.path) else {
            throw VoiceError.processFailed(component: "piper", status: -1,
                                           stderr: "No output audio at \(outputPath.path).")
        }
        return outputPath
    }
}
