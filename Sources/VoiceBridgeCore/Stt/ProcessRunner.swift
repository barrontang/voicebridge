import Foundation

/// One child-process invocation.
public struct ProcessInvocation: Sendable {
    /// The executable (an **absolute** path - `Process` does not search `$PATH`).
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    /// Bytes written to the child's stdin; the pipe is closed afterwards so
    /// the child sees EOF.
    public var standardInput: Data?
    /// Seconds before the child is terminated (nil = wait forever).
    public var timeout: TimeInterval?

    public init(executable: String,
                arguments: [String] = [],
                workingDirectory: String? = nil,
                standardInput: Data? = nil,
                timeout: TimeInterval? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeout = timeout
        }
}

/// The result of a finished child process.
public struct ProcessOutcome: Sendable {
    public let stdout: String
    public let stderr: String
    public let status: Int32
    /// True when the child was killed because it overran its timeout.
    public let timedOut: Bool

    public init(stdout: String, stderr: String, status: Int32, timedOut: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.timedOut = timedOut
        }
}

/// A robust `Process` runner.
///
/// The old implementation (in `Shell` and `Pipeline`, duplicated) had three
/// real bugs, all fixed here:
///
///   * **A launch failure could hang forever.** When `process.run()` throws,
///     the parent still holds the *write* ends of the pipes, so the readers
///     never see EOF and the drain awaits never return. The write ends are
///     now closed explicitly on that path.
///   * **`waitUntilExit()` blocked a cooperative thread.** The exit is now
///     awaited through a continuation fed by `terminationHandler`.
///   * **Writing stdin happened on the calling thread.** A payload larger
///     than the pipe buffer (64 KB) blocked the executor; the write now
///     happens on a detached task.
///
/// Both pipes are drained concurrently, so a large transcript can never fill
/// a pipe buffer and deadlock the child, and cancellation terminates the
/// child instead of orphaning it.
public enum ProcessRunner {

    /// Run a child process to completion.
    public static func run(_ invocation: ProcessInvocation) async throws -> ProcessOutcome {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        if let dir = invocation.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
            }
        process.standardOutput = outPipe
        process.standardError = errPipe
        if invocation.standardInput != nil {
            process.standardInput = inPipe
            }

        let exit = ExitSignal()
        process.terminationHandler = { p in exit.signal(p.terminationStatus) }

        // Drain both pipes concurrently, *before* we wait for the exit.
        let outTask = Task.detached(priority: .userInitiated) { readAll(outPipe) }
        let errTask = Task.detached(priority: .userInitiated) { readAll(errPipe) }

        do {
            try process.run()
            } catch {
            // The child never started. Close the write ends so the readers
            // hit EOF instead of blocking forever.
            outPipe.fileHandleForWriting.closeFile()
            errPipe.fileHandleForWriting.closeFile()
            inPipe.fileHandleForWriting.closeFile()
            _ = await outTask.value
            _ = await errTask.value
            throw VoiceError.binaryNotFound(
                component: invocation.executable,
                hint: "run() failed: \(error)")
            }

        // Feed stdin off the calling thread and close it (the child must see
        // EOF - Piper and Kokoro both wait for it).
        let stdinWrite = Task.detached(priority: .userInitiated) {
            if let data = invocation.standardInput {
                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
            try? inPipe.fileHandleForWriting.close()
            }

        // Cancellation terminates the child (no orphaned 30-minute
        // transcription after the user hits Stop).
        let status: Int32
        var timedOut = false
        do {
            status = try await withTaskCancellationHandler {
                try await waitForExit(exit,
                                      timeout: invocation.timeout,
                                      component: invocation.executable,
                                      // The child has to die *before* the
                                      // timeout error propagates: the exit
                                      // waiter only finishes when the
                                      // termination handler fires.
                                      onTimeout: { process.terminate() })
                } onCancel: {
                process.terminate()
                }
            } catch {
            timedOut = true
            process.terminate()
            _ = await exit.wait()
            await stdinWrite.value
            // The drains are NOT awaited here on purpose: a grandchild
            // process can keep the pipe open long after the child we
            // killed is gone (e.g. `sh -c "sleep 30"`), and waiting for
            // EOF would hang the caller. The drain tasks finish on their
            // own when the pipe finally closes.
            throw error
            }

        await stdinWrite.value
        let out = await outTask.value
        let err = await errTask.value

        return ProcessOutcome(stdout: out, stderr: err, status: status, timedOut: timedOut)
    }

    /// Await the child's exit, enforcing the timeout.
    ///
    /// The timeout is a timer, not a racing task group: a task group waits
    /// for *every* child before it returns, and the child that waits for the
    /// exit can only finish when the process dies - so the timeout has to
    /// kill the child first, which is exactly what the timer does.
    private static func waitForExit(_ exit: ExitSignal,
                                    timeout: TimeInterval?,
                                    component: String,
                                    onTimeout: @escaping () -> Void) async throws -> Int32 {
        guard let timeout else { return await exit.wait() }

        let flag = TimeoutFlag()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            flag.fire()
            onTimeout()
            }
        timer.resume()
        defer { timer.cancel() }

        let status = await exit.wait()
        if flag.fired {
            throw VoiceError.processTimeout(component: component, seconds: timeout)
            }
        return status
    }

    /// Read a pipe to EOF.
    private static func readAll(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// A one-shot flag ("the timeout fired").
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var didFire = false

    var fired: Bool { lock.lock(); defer { lock.unlock() }; return didFire }

    func fire() {
        lock.lock()
        didFire = true
        lock.unlock()
    }
}

/// A signal for the child's exit status.
///
/// The termination handler can fire before *or* after the caller starts
/// waiting, so the status is latched. Several callers may wait for the same
/// exit (the timeout path and the cleanup path both do): every waiter is
/// resumed, and a waiter that arrives late gets the latched status
/// immediately.
final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Int32, Never>] = []
    private var status: Int32?

    /// The child's exit status (waits for it if it has not exited yet).
    func wait() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let status {
                lock.unlock()
                cont.resume(returning: status)
                return
                }
            continuations.append(cont)
            lock.unlock()
            }
    }

    /// Called from the termination handler.
    func signal(_ value: Int32) {
        lock.lock()
        status = value
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        for cont in waiting { cont.resume(returning: value) }
    }
}
