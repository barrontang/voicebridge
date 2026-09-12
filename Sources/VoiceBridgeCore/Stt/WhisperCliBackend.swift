import Foundation

/// Runs the whisper.cpp `whisper-cli` binary. whisper-cpp on Apple Silicon is
/// Metal-accelerated by default, so this path uses the GPU + unified memory out
/// of the box.
///
/// This is the *out-of-process* implementation — correct and runnable, but note
/// the packaging caveat in docs/ARCHITECTURE.md: an out-of-process binary does
/// not survive the App Sandbox. The recommended *shipping* path is link
/// whisper.cpp in-process; this scaffold uses the process path so you can run
/// and observe it today, before a C/C++ link step.
///
/// Cross-version note (output shape):
///    * modern ggerganov/whisper.cpp treats `-otxt` / `-oj` as boolean flags and
///      derives the output filename from the *input* basename, writing
///      `<input>.txt` and `<input>.json` in the current working directory;
///      stdout carries only a `"Done."` sentinel.
///    * older builds print the transcript to stdout and have no `-otxt` flag.
///
/// `transcribe` therefore runs in a per-call temp CWD, asks for both an on-disk
/// transcript and JSON, locates the derived files (with a directory-scan
/// fallback for variant naming), and falls back to parsing stdout when the
/// binary predates these flags. Audio duration is measured from the source file
/// (a model's offset can be its 30 s context window, which would skew any ratio).
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
            ///       1. env `WHISPER_CLI`
            ///       2. App-bundle resource `whisper-cli` (when linked into a shipping app)
            ///       3. Homebrew whisper-cpp (Apple Silicon + Intel prefixes)
            ///       4. `whisper-cli` on `$PATH`
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

            /// Whether a non-zero exit was caused by an *unrecognized option* (an
            /// old binary that predates `-otxt`/`-oj`), as opposed to a genuine
            /// transcription failure that must be re-thrown.
    private func isUnrecognizedOptionError(_ error: VoiceError) -> Bool {
        guard case .processFailed(let component, _, let stderr) = error,
             component.lowercased().contains("whisper") else { return false }
        let s = stderr.lowercased()
        return s.contains("unrecognized")
                 || s.contains("unknown option")
                 || s.contains("invalid option")
                 || s.contains("option not found")
                 || s.contains("unknown arg")
            }

            /// Recursively find the first regular file under `dir` with the given
            /// extension (covers builds that name the output file differently).
    private func firstFile(at dir: URL, withExtension ext: String) -> String? {
        guard let entries = try? FileManager.default
              .contentsOfDirectory(at: dir,
                                   includingPropertiesForKeys: [.isRegularFileKey],
                                   options: [.skipsHiddenFiles])
             else { return nil }
        return entries.first { $0.pathExtension == ext }?.path
             }

            /// `<workDir>/<base>.<ext>` — the filename whisper.cpp derives from
            /// the input basename (it keeps the original extension, e.g.
            /// `in.wav` → `in.wav.json`).
    private func derived(_ workDir: URL, base: String, ext: String) -> String {
        workDir.appendingPathComponent("\(base).\(ext)").path
                }

    public func transcribe(audio: URL,
                           language: String?,
                           model: SttModel,
                           useTimestamps: Bool) async throws -> Transcription {
        let modelPath = try requireModelURL(for: model)
        let binary = try resolveBinary()

             // Each invocation gets an isolated temp CWD. whisper.cpp derives its
             // output filenames from the input basename, so we both predict the
             // name and scan the dir to confirm, rather than trusting one name.
        let uuid = UUID().uuidString.lowercased()
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
                         .appendingPathComponent("voicebridge-\(uuid)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir,
                                                withIntermediateDirectories: true)
        let baseName = audio.lastPathComponent                // e.g. "in.wav"

             // Common args: model, file, language (nil = auto-detect),
             // no-timestamps, progress.
        var baseArgs = ["-m", modelPath.path, "-f", audio.path]
        if let language { baseArgs += ["-l", language] }
        if !useTimestamps { baseArgs.append("-nt") }          // clean text only
        baseArgs += ["-pp"]                                    // print progress

        let started = Date()
        var stdout = ""
        do {
              // Modern attempt: ask for an on-disk transcript + JSON metadata.
            let result = try await Shell.run(
                at: binary,
                arguments: baseArgs + ["-otxt", "-oj"],
                workingDirectory: workDir.path)
            stdout = result.stdout
            } catch let error as VoiceError where isUnrecognizedOptionError(error) {
                // The binary predates `-otxt`/`-oj`: it prints the transcript to
                // stdout instead. Retry without those flags. We only retry on
                // *option-parsing* failures, so genuine transcription errors
                // still surface to the caller.
            let result = try await Shell.run(at: binary, arguments: baseArgs,
                                             workingDirectory: workDir.path)
            stdout = result.stdout
            }
        let elapsed = Date().timeIntervalSince(started)

             // Locate the derived output files. Preference order: predicted
             // `<base>.<ext>` → any `*.<ext>` found in the work dir.
        let txtPath = (FileManager.default.fileExists(atPath: derived(workDir, base: baseName, ext: "txt"))
                 ? derived(workDir, base: baseName, ext: "txt")
                 : firstFile(at: workDir, withExtension: "txt"))
        let jsonPath = (FileManager.default.fileExists(atPath: derived(workDir, base: baseName, ext: "json"))
                 ? derived(workDir, base: baseName, ext: "json")
                 : firstFile(at: workDir, withExtension: "json"))

             // Text source priority: on-disk transcript → stdout (old builds).
        var text = ""
        if let txtPath {
            text = WhisperTranscriptParser.loadText(atPath: txtPath)
                 }
        if text.isEmpty {
            text = WhisperTranscriptParser.plainText(from: stdout)
                  }

             // Detect the spoken language from JSON when available.
        var detectedLanguage = language ?? "auto"
        if let jsonPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
           let meta = WhisperTranscriptParser.parseJSON(data) {
            if !meta.text.isEmpty { text = meta.text }
            if !meta.language.isEmpty { detectedLanguage = meta.language }
                 }

             // Prefer a duration measured from the source file: a model's offset
             // can be its 30 s context window, which would skew the factor. Fall
             // back to the JSON-derived duration only when the file is unreadable.
        var durationSeconds = AudioDuration.estimateSeconds(at: audio)
        if durationSeconds <= 0,
           let jsonPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: jsonPath)),
           let meta = WhisperTranscriptParser.parseJSON(data),
           meta.durationSeconds > 0 {
            durationSeconds = meta.durationSeconds
                 }

             // realtimeFactor is wallclock / audio length (~1 == realtime, <1
             // faster). Only meaningful once we know the true audio duration;
             // otherwise report the raw wallclock as a cost proxy.
        let realtimeFactor = durationSeconds > 0 ? elapsed / durationSeconds : elapsed

             // Best-effort cleanup of the per-run scratch dir.
        try? FileManager.default.removeItem(at: workDir)

        return Transcription(
            text: text,
            language: detectedLanguage,
            model: model,
            durationSeconds: durationSeconds,
            realtimeFactor: realtimeFactor)
             }
}
