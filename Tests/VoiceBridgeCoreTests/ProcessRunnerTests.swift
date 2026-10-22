import XCTest
@testable import VoiceBridgeCore

/// Tests for the process runner.
///
/// They use `/bin/sh` scripts (no external tools, no network) to cover the
/// three failure modes the old implementation had:
///
///   * a launch failure must not hang,
///   * a child that overruns its timeout must be terminated and reported,
///   * a payload bigger than the pipe buffer must not deadlock the caller,
///
/// plus the ordinary contract: stdout, stderr and the exit status.
final class ProcessRunnerTests: XCTestCase {

    // MARK: - Happy path

    func testCapturesStdoutAndStderr() async throws {
        let outcome = try await ProcessRunner.run(ProcessInvocation(
            executable: "/bin/sh",
            arguments: ["-c", "echo out; echo err 1>&2; exit 0"]))
        XCTAssertEqual(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "out")
        XCTAssertEqual(outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines), "err")
        XCTAssertEqual(outcome.status, 0)
        XCTAssertFalse(outcome.timedOut)
    }

    func testReportsANonZeroExit() async throws {
        // The runner reports the status; the *wrappers* (Shell / Pipeline)
        // are the ones that turn a non-zero exit into an error.
        let outcome = try await ProcessRunner.run(ProcessInvocation(
            executable: "/bin/sh",
            arguments: ["-c", "exit 3"]))
        XCTAssertEqual(outcome.status, 3)
    }

    func testShellWrapperThrowsOnNonZeroExit() async throws {
        do {
            _ = try await Shell.run(at: "/bin/sh", arguments: ["-c", "exit 7"])
            XCTFail("expected a failure")
        } catch {
            guard case VoiceError.processFailed(_, let status, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(status, 7)
        }
    }

    // MARK: - stdin

    func testWritesStdinAndClosesIt() async throws {
        let outcome = try await ProcessRunner.run(ProcessInvocation(
            executable: "/bin/cat",
            standardInput: Data("hello from stdin".utf8)))
        XCTAssertEqual(outcome.stdout, "hello from stdin")
    }

    func testLargeStdinDoesNotDeadlock() async throws {
        // 1 MB is far beyond the 64 KB pipe buffer: the writer has to be
        // drained while the write is in progress.
        let payload = String(repeating: "a", count: 1_000_000)
        let outcome = try await ProcessRunner.run(ProcessInvocation(
            executable: "/bin/sh",
            arguments: ["-c", "wc -c | tr -d ' '"],
            standardInput: Data(payload.utf8)))
        XCTAssertEqual(outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       "1000000")
    }

    func testPipelineFeedsStdin() async throws {
        let outcome = try await ProcessRunner.run(ProcessInvocation(
            executable: "/bin/cat",
            standardInput: Data("piped".utf8)))
        XCTAssertEqual(outcome.stdout, "piped")
    }

    // MARK: - Failure modes

    func testLaunchFailureDoesNotHang() async throws {
        // A path that cannot be executed: the runner must fail fast instead
        // of waiting for an EOF that never comes.
        let start = Date()
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executable: "/nonexistent/definitely-not-here"))
            XCTFail("expected a failure")
        } catch {
            guard case VoiceError.binaryNotFound = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5,
                          "the launch failure must not block")
    }

    func testTimeoutTerminatesTheChild() async throws {
        let start = Date()
        do {
            _ = try await ProcessRunner.run(ProcessInvocation(
                executable: "/bin/sh",
                arguments: ["-c", "exec sleep 30"],
                timeout: 0.5))
            XCTFail("expected a timeout")
        } catch {
            guard case VoiceError.processTimeout = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 10, "the child should have been killed early")
    }

    func testShellRunHonoursTheTimeout() async throws {
        do {
            _ = try await Shell.run(at: "/bin/sh",
                                    arguments: ["-c", "exec sleep 30"],
                                    timeout: 0.5)
            XCTFail("expected a timeout")
        } catch {
            guard case VoiceError.processTimeout = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testCancellationTerminatesTheChild() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(ProcessInvocation(
                executable: "/bin/sh",
                arguments: ["-c", "exec sleep 30"]))
        }
        // Give the child a moment to start, then cancel.
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()

        do {
            _ = try await task.value
            // The runner may report the non-zero exit of the killed child;
            // what matters is that it returned instead of running for 30 s.
        } catch {
            // A cancellation error is fine too.
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "cancellation must not wait for the child")
    }
}
