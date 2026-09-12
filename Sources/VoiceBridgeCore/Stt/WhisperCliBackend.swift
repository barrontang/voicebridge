import Foundation

/// Runs the whisper.cpp `whisper-cli` binary. whisper-cpp on Apple Silicon is
/// Metal-accelerated by default, so this path uses the GPU + unified memory out
/// of the box.
///
/// This is the *out-of-process* implementation — correct and runnable, but note
/// the packaging caveat in docs/ARCHITECTURE.md: an out-of-process binary does
/// not survive the App Sandbox. The recommended *shipping* path is to link
/// whisper.cpp in-process; this scaffold uses the process path so you can run
/// and observe it today, before a C/C++ link step.
public final class WhisperCliBackend: WhisperBackend, @unchecked Sendable {

       /// Model files live under `<root>/whisper/ggml-<model>.bin`.
    private let modelDirectory: URL

    public init(modelDirectory: URL = ModelPaths.whisperDir) {
        self.modelDirectory = modelDirectory
       }

      /// Absolute path to the model file, or nil (not yet downloaded).
    public func modelURL(for model: SttModel) -> URL? {
        let url = modelDirectory.appendingPathComponent(model.ggmlFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
       }

      /// Ensures the model file exists; returns its URL or throws.
    private func requireModelURL(for model: SttModel) throws -> URL {
        if let url = modelURL(for: model) { return url }
        throw VoiceError.modelMissing(model: model.ggmlFilename, directory: modelDirectory.path)
       }

      /// Binary resolution order:
      ///    1. env `WHISPER_CLI`
      ///    2. App-bundle resource `whisper-cli` (when linked into a shipping app)
      ///    3. Homebrew whisper-cpp (Apple Silicon + Intel prefixes)
      ///    4. `whisper-cli` on $PATH
    private func resolveBinary() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let p = env["WHISPER_CLI"], FileManager.default.isExecutableFile(atPath: p) {
            return p
           }
        if let bundleURL = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) {
            return bundleURL.path
            }
        for candidate in [
              "/opt/homebrew/opt/whisper-cpp/bin/whisper-cli",
              "/usr/local/opt/whisper-cpp/bin/whisper-cli"
            ] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
            }
        if let onPath = Shell.pathLookup("whisper-cli") {
            return onPath
            }
        throw VoiceError.binaryNotFound(
            component: "whisper-cli",
            hint: "Install via `brew install whisper-cpp` or set the WHISPER_CLI env var.")
       }

    public func transcribe(audio: URL,
                           language: String?,
                           model: SttModel,
                           useTimestamps: Bool) async throws -> Transcription {
        let modelPath = try requireModelURL(for: model)
        let binary = try resolveBinary()

        var args = ["-m", modelPath.path, "-f", audio.path]
        if let language { args += ["-l", language] }
        if !useTimestamps { args.append("-nt") }    // clean text only
        args += ["-pp"]                              // print progress
          // NOTE: newer whisper-cli writes the transcript with `-oj`/`-otxt`;
           // older builds print to stdout. Tune the flag to your binary.

        let started = Date()
        let result = try await Shell.run(at: binary, arguments: args,
                                         workingDirectory: modelDirectory.path)
        let elapsed = Date().timeIntervalSince(started)

        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcription(
             text: text,
             language: language ?? "auto",
             model: model,
             durationSeconds: 0,
             realtimeFactor: elapsed)
       }
}
