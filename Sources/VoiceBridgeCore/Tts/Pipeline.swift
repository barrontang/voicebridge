import Foundation

/// Runs a binary feeding text from stdin — the pattern Piper / edge-tts /
/// Kokoro-python all use. Drains stdout AND stderr on background queues (to
/// avoid the classic pipe-buffer deadlock) via a DispatchGroup join, honors a
/// `timeout` (terminating overrunning children), and throws on non-zero exit.
public enum Pipeline {

      public static func runWithStdin(input: String,
                                       at argv: [String],
                                       workingDirectory: String? = nil,
                                       timeout: TimeInterval? = nil) async throws {
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
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
              }

        let drain = DispatchGroup()
        var capturedErr = Data()

        drain.enter()
        DispatchQueue.global().async {
                 _ = outPipe.fileHandleForReading.readDataToEndOfFile()
                 drain.leave()
                  }

        drain.enter()
        DispatchQueue.global().async {
                let d = errPipe.fileHandleForReading.readDataToEndOfFile()
                 withLock { capturedErr = d }
                 drain.leave()
                  }

        let watch = Shell.TimeoutWatch()
        var timer: DispatchSourceTimer?

        // Missing 2: if the calling Task is cancelled (Stop / quit / app close),
        // terminate the child instead of orphaning it for the full engine run.
        _ = try await withTaskCancellationHandler {
             do {
                try process.run()
                timer = Shell.armTimeout(process, after: timeout, watch: watch)
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
            timer?.cancel()
            drain.wait()
            let status = process.terminationStatus
            let errText = withLockedString { String(data: capturedErr, encoding: .utf8) ?? "" }

                // A timeout kill means the engine hung — surface it distinctly.
            if watch.wasTerminated {
                throw VoiceError.processTimeout(component: argv[0],
                                               seconds: timeout ?? -1)
             }
            if Task.isCancelled {
                throw CancellationError()
             }
            if status != 0 {
                throw VoiceError.processFailed(component: argv[0], status: status, stderr: errText)
             }
                  } onCancel: {
                     // `terminate()` is a no-op on an already-exited child.
                  process.terminate()
                       }
         }

          // Tiny lock so the captured stderr can be read across threads safely.
    private static let lock = NSLock()

     private static func withLock(_ body: () -> Void) {
        lock.lock(); body(); lock.unlock()
           }
     private static func withLockedString(_ body: () -> String) -> String {
        lock.lock(); defer { lock.unlock() }
        return body()
          }
}
