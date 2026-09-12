import Foundation

/// Runs a binary feeding text from stdin — the pattern Piper / edge-tts /
/// Kokoro-python all use. Drains stderr on a background queue (to avoid the
/// classic pipe-buffer deadlock) via a DispatchGroup join, and throws on
/// non-zero exit.
public enum Pipeline {

      public static func runWithStdin(input: String,
                                       at argv: [String],
                                       workingDirectory: String? = nil,
                                       timeout: TimeInterval? = nil) throws {
        guard !argv.isEmpty else {
            throw VoiceError.binaryNotFound(component: "(empty)", hint: "No argv provided.")
            }

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput = inPipe
        process.standardOutput = outPipe      // engines write to --output_file
        process.standardError = errPipe
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
           }

         // Drain stderr concurrently so the child can't block on a full pipe
           // buffer while we wait for termination. The DispatchGroup gives us a
           // clean join so we can read stderr *after* the process exits.
        let drain = DispatchGroup()
        var capturedErr = Data()
        drain.enter()
        DispatchQueue.global().async {
                 let d = errPipe.fileHandleForReading.readDataToEndOfFile()
                  withLock { capturedErr = d }
                 drain.leave()
               }

        do {
            try process.run()
              } catch {
            drain.wait()
            let errText = withLockedString { String(data: capturedErr, encoding: .utf8) ?? "(no stderr)" }
            throw VoiceError.binaryNotFound(
                component: argv[0],
                hint: "run() failed: \(error)\n\(errText)")
              }

         // Write stdin, then close so the child sees EOF (crucial for Piper).
        let handle = inPipe.fileHandleForWriting
        do { try handle.write(contentsOf: Data(input.utf8)) } catch {}
        try? handle.close()

        process.waitUntilExit()
        drain.wait()
        let status = process.terminationStatus
        let errText = withLockedString { String(data: capturedErr, encoding: .utf8) ?? "" }

        if status != 0 {
            throw VoiceError.processFailed(component: argv[0], status: status, stderr: errText)
          }
        }

       // Tiny lock helpers so the captured stderr can be read safely.
    private static var lock = NSLock()
    private static var withLockClosure: (() -> Void)? = nil

    private static func withLock(_ body: () -> Void) {
        lock.lock(); body(); lock.unlock()
         }
    private static func withLockedString(_ body: () -> String) -> String {
        lock.lock(); defer { lock.unlock() }
        return body()
        }
}
