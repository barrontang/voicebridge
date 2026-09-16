import Foundation

/// Piper: a local, ONNX-based TTS engine (rhasspy/piper). Fully offline;
/// installs via `scripts/install-piper.sh` and voices live under
/// `<root>/piper/voice/<name>.onnx` + `<name>.onnx.json` (the config).
///
/// CLI shape: `printf '%s' "text" | piper -m model.onnx -f out.wav`
/// (`-m` model, `-f` output WAV, text on stdin; the `.onnx.json` sidecar is
/// auto-loaded for config).
///
/// Finding 2: `modelDirectory` is now *passed in* (the manager resolves it from
/// the user's chosen root). The old code read the static `ModelPaths.piperVoiceDir`
/// internally, so a custom model folder was ignored at synthesis time even though
/// the picker showed voices from it — a silent "voice not found" failure.
    // SAFETY (@unchecked Sendable): all stored properties are immutable `let`s.
    // A future mutable cache must be an `actor` or locked, not a bare var.
public final class PiperBackend: TTSBackend, @unchecked Sendable {

     private let binary: String
     private let binaryLocator: BinaryLocator
     private let modelDirectory: URL

     public init(modelDirectory: URL,
                 binaryLocator: BinaryLocator = BinaryLocator(),
                 binaryOverride: String? = nil) {
        self.modelDirectory = modelDirectory
        self.binaryLocator = binaryLocator
         // A supplied override/env var wins; otherwise resolve "piper" through the
         // shared locator. `resolve(preferred:)` handles env + search + passthrough.
        let raw = binaryOverride
              ?? ProcessInfo.processInfo.environment["VOICEBRIDGE_PIPER"]
        if let raw {
             self.binary = raw
          } else {
             self.binary = binaryLocator.resolve(preferred: "VOICEBRIDGE_PIPER", "piper")
            }
        }

     public var displayName: String { "Piper \(modelDirectory.lastPathComponent)" }

        /// Available when its binary is present (override/env or on PATH).
    public func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: binary)
          || binaryLocator.isAvailable("piper")
         }

     public func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
          // Missing 2: bail early on caller cancellation.
        try Task.checkCancellation()

          // Resolve to a concrete .onnx path.
        let model: URL
        if let voice, voice.contains("/") {
            model = URL(fileURLWithPath: voice)
          } else {
            var v = voice ?? "en_US-lessac-medium"            // sensible default
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
        try await Pipeline.runWithStdin(input: text, at: args,
                                   workingDirectory: modelDirectory.path,
                           timeout: 120)

        guard FileManager.default.fileExists(atPath: outputPath.path) else {
            throw VoiceError.processFailed(component: "piper", status: -1,
                                           stderr: "No output audio at \(outputPath.path).")
             }
        return outputPath
          }
}
