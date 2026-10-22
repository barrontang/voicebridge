import Foundation

/// A small, async-friendly wrapper over `Process`.
///
/// Fixes the original PRD's three bugs:
///    * no hardcoded `/usr/local/bin/...` path — the caller resolves the binary,
///    * no blocking `readDataToEndOfFile` on the calling thread — the pipe is
///      drained on a background queue while we concurrently await termination,
///    * non-zero exit now surfaces as a thrown `VoiceError` (not silent success).
///
/// Also adds a real `timeout`: a child that overruns it is `terminate()`d and
/// surfaced as `.processTimeout` — so a broken engine (e.g. an orphaned Kokoro
/// runtime that hangs on import) can no longer freeze the app.
///
/// The heavy lifting lives in `ProcessRunner` (shared with `Pipeline`), which
/// also fixes the launch-failure hang and the blocking `waitUntilExit()`.
public enum Shell {

    public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
    }

    /// Runs a binary, draining both pipes concurrently so large output never
    /// deadlocks the process, and throws on non-zero exit or timeout.
    public static func run(at binary: String,
                          arguments: [String],
                          workingDirectory: String? = nil,
                          timeout: TimeInterval? = nil) async throws -> Result {
        guard !isBlank(binary) else {
            throw VoiceError.binaryNotFound(component: "(empty)", hint: "No binary was provided.")
         }

        let outcome = try await ProcessRunner.run(ProcessInvocation(
            executable: binary,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout))

        if outcome.timedOut {
            throw VoiceError.processTimeout(component: binary,
                                            seconds: timeout ?? -1)
            }
        if outcome.status != 0 {
            throw VoiceError.processFailed(component: binary,
                                           status: outcome.status,
                                           stderr: outcome.stderr)
            }
        return Result(stdout: outcome.stdout, stderr: outcome.stderr, status: outcome.status)
     }

    /// Resolve a bare command name to an absolute executable path on `$PATH`.
    ///
    /// The classic bug this fixes: backends check availability via `pathLookup`
    /// (which resolves the absolute path) but then handed the *bare name* to
    /// `Process(executableURL:)`, which needs an absolute path. A relative name
    /// makes `Process.run()` fail to launch the child — the process silently
    /// never starts and the caller hangs. Always resolve to an absolute path
    /// before handing off to `Pipeline`.
    public static func resolve(_ input: String) -> String {
        if FileManager.default.isExecutableFile(atPath: input) { return input }
         // Not a directly-executable path: search $PATH by the command's
        // basename. Falls back to the original input if genuinely absent.
        if let abs = pathLookup((input as NSString).lastPathComponent) { return abs }
        return input
    }

    /// Resolve an executable on `$PATH` the way a shell does.
    public static func pathLookup(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        for dir in (env["PATH"] ?? "").components(separatedBy: ":") {
            let candidate = ((dir as NSString).appendingPathComponent(name))
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
             }
         }
        return nil
    }

    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
