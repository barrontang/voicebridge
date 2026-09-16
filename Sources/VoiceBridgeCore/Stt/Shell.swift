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

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
         }
        process.standardOutput = outPipe
        process.standardError = errPipe

         // Read both pipes on background queues BEFORE we wait, so a large
         // transcript can't fill the pipe buffer and stall the process.
        let stdoutTask = Task { try await drain(outPipe) }
        let stderrTask = Task { try await drain(errPipe) }

        let watch = TimeoutWatch()
        var timer: DispatchSourceTimer?

        do {
            try process.run()
            timer = armTimeout(process, after: timeout, watch: watch)
         } catch {
            let stderrText = (try? await stderrTask.value) ?? ""
            throw VoiceError.binaryNotFound(component: binary,
                                             hint: "run() failed: \(error). stderr:\n\(stderrText)")
         }

          // Missing 2: honor caller cancellation. Without this, a Stop / app-quit
          // leaves the engine (e.g. whisper on a 30-min file) running to
          // completion — an orphan process. `onCancel` terminates the child; the
          // pipes are already being drained on their own tasks.
        let collected = try await withTaskCancellationHandler {
            var out = ""
            var err = ""
            do { out = try await stdoutTask.value } catch {}
            do { err = try await stderrTask.value } catch {}

            process.waitUntilExit() // terminates cleanly now that pipes are drained
            timer?.cancel()
            let status = process.terminationStatus

              // A timeout kill is a failure even though SIGTERM exits non-zero.
            if watch.wasTerminated {
                throw VoiceError.processTimeout(component: binary,
                                                seconds: timeout ?? -1)
               }
            if status != 0 {
                throw VoiceError.processFailed(component: binary, status: status, stderr: err)
               }
            return Result(stdout: out, stderr: err, status: status)
                } onCancel: {
                  // `terminate()` is a no-op on an already-exited child.
                process.terminate()
                stdoutTask.cancel()
                stderrTask.cancel()
                     }

        return collected
     }

     /// Reads a pipe to EOF on a background queue.
    private static func drain(_ pipe: Pipe) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: text)
             }
         }
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

       /// Tracks a child `Process` so a `timeout` can terminate it without racy
        /// flag handling. `markDone()` is wired to `terminationHandler`; the
         /// returned timer fires `terminate()` if the child is still running when
          /// the deadline passes. A natural exit marks done *before* the timer
           /// reads, so a fast child is never mistaken for a timeout.
      final class TimeoutWatch: @unchecked Sendable {
           private let lock = NSLock()
           private var done = false
           private var terminated = false
            /// True iff *we* terminated the child (i.e., it exceeded the timeout).
           var wasTerminated: Bool { lock.lock(); defer { lock.unlock() }; return terminated }
             /// Called from `process.terminationHandler` on natural exit.
           func markDone() { lock.lock(); done = true; lock.unlock() }
                /// Returns true only if the child was still live when the timer
                 /// fired — that caller is the one that must terminate it.
           func armIfNeeded() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; terminated = true; return true }
            }

         /// Wire a termination handler + a timer that terminates the child after
          /// `timeout` (nil = wait forever). Returns the armed timer (or nil).
         @discardableResult
        static func armTimeout(_ process: Process,
                               after timeout: TimeInterval?,
                               watch: TimeoutWatch) -> DispatchSourceTimer? {
             process.terminationHandler = { _ in watch.markDone() }
             guard let timeout else { return nil }
             let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
             timer.schedule(deadline: .now() + timeout)
             timer.setEventHandler { if watch.armIfNeeded() { process.terminate() } }
             timer.resume()
             return timer
          }
}
