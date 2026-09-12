import Foundation

/// A small, async-friendly wrapper over `Process`.
///
/// Fixes the original PRD's three bugs:
///  * no hardcoded `/usr/local/bin/...` path — the caller resolves the binary,
///  * no blocking `readDataToEndOfFile` on the calling thread — the pipe is
///    drained on a background queue while we concurrently await termination,
///  * non-zero exit now surfaces as a thrown `VoiceError` (not silent success).
public enum Shell {

     public struct Result: Sendable {
        public let stdout: String
        public let stderr: String
        public let status: Int32
     }

     /// Runs a binary, draining both pipes concurrently so large output never
     /// deadlocks the process, and throws on non-zero exit.
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

        do {
            try process.run()
         } catch {
            let stderrText = (try? await stderrTask.value) ?? ""
            throw VoiceError.binaryNotFound(component: binary,
                                            hint: "run() failed: \(error). stderr:\n\(stderrText)")
         }

        var out = ""
        var err = ""
        do { out = try await stdoutTask.value } catch {}
        do { err = try await stderrTask.value } catch {}

        process.waitUntilExit() // terminates cleanly now that pipes are drained
        let status = process.terminationStatus

        if status != 0 {
            throw VoiceError.processFailed(component: binary, status: status, stderr: err)
          }
        return Result(stdout: out, stderr: err, status: status)
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
