import Foundation

/// Runs a binary feeding text from stdin — the pattern Piper / edge-tts /
/// Kokoro-python all use.
///
/// The pipes are drained concurrently (so the classic pipe-buffer deadlock
/// cannot happen), the child is terminated when it overruns its timeout, and
/// a non-zero exit surfaces as a `VoiceError`. The implementation is shared
/// with `Shell` through `ProcessRunner`.
public enum Pipeline {

      public static func runWithStdin(input: String,
                                       at argv: [String],
                                       workingDirectory: String? = nil,
                                       timeout: TimeInterval? = nil) async throws {
        guard !argv.isEmpty else {
            throw VoiceError.binaryNotFound(component: "(empty)", hint: "No argv provided.")
               }

        let outcome = try await ProcessRunner.run(ProcessInvocation(
            executable: argv[0],
            arguments: Array(argv.dropFirst()),
            workingDirectory: workingDirectory,
            standardInput: Data(input.utf8),
            timeout: timeout))

        if outcome.timedOut {
            throw VoiceError.processTimeout(component: argv[0],
                                           seconds: timeout ?? -1)
            }
        if outcome.status != 0 {
            throw VoiceError.processFailed(component: argv[0],
                                           status: outcome.status,
                                           stderr: outcome.stderr)
            }
        }
}
