import XCTest

@testable import VoiceBridgeCore

/// The DSH voice interface's client: locating `dsh`, the argument vector, and
/// turning headless output into something worth reading aloud.
final class DSHClientTests: XCTestCase {

    func testArgumentsCarryProfilePatchesAndTheWholePrompt() {
        let args = DSHClient.arguments(
            prompt: "今天天气怎么样？ \"quoted\"",
            profile: "headless",
            patches: ["/a.yml", "/b.yml"])
        XCTAssertEqual(
            args,
            [
                "--profile", "headless", "--patch", "/a.yml", "--patch", "/b.yml", "--json",
                "今天天气怎么样？ \"quoted\"",
            ])
    }

    /// A follow-up turn resumes the session, which is what makes it a chat.
    func testAFollowUpTurnResumesTheSession() {
        let args = DSHClient.arguments(
            prompt: "now run the tests", profile: "headless", patches: [], session: "session-abc")
        XCTAssertEqual(
            args,
            ["--profile", "headless", "--json", "--session-id", "session-abc", "now run the tests"])
    }

    /// The real event shape DSH's headless `--json` mode emits.
    func testTheEventStreamYieldsTheAnswerAndTheSession() {
        let stdout = """
            {"type":"session","sessionId":"session-37128f81","cwd":"/tmp"}
            {"type":"status","phase":"turn_start","turn":1}
            {"type":"thinking","text":"The user wants me to remember 42."}
            {"type":"text","text":"ok"}
            {"type":"final","sessionId":"session-37128f81","reason":{"kind":"completed"},"text":"ok"}
            """
        let parsed = DSHClient.parseEvents(stdout)
        XCTAssertEqual(parsed.text, "ok", "thinking must never be part of the answer")
        XCTAssertEqual(parsed.sessionID, "session-37128f81")
    }

    /// An interrupted turn has no `final`; the streamed text is the answer.
    func testStreamedTextIsUsedWithoutAFinalEvent() {
        let stdout = """
            {"type":"session","sessionId":"s1"}
            {"type":"text","text":"Hello, "}
            {"type":"text","text":"world."}
            """
        XCTAssertEqual(DSHClient.parseEvents(stdout).text, "Hello, world.")
    }

    func testPlainTextOutputStillWorks() {
        let parsed = DSHClient.parseEvents("just an answer\n")
        XCTAssertEqual(parsed.text, "just an answer")
        XCTAssertNil(parsed.sessionID)
    }

    func testLocatePrefersTheOverrideThenPathThenTheAppBundle() {
        let env = ["VOICEBRIDGE_DSH": "/custom/dsh", "PATH": "/usr/bin:/opt/bin"]
        XCTAssertEqual(DSHClient.locate(environment: env) { _ in true }, "/custom/dsh")

        XCTAssertEqual(
            DSHClient.locate(environment: ["PATH": "/usr/bin:/opt/bin"]) { $0 == "/opt/bin/dsh" },
            "/opt/bin/dsh")

        XCTAssertEqual(
            DSHClient.locate(environment: [:]) { $0 == DSHClient.appBundleLauncher },
            DSHClient.appBundleLauncher)

        XCTAssertNil(DSHClient.locate(environment: [:]) { _ in false })
    }

    /// A thinking model prefixes its answer with its reasoning; only the
    /// answer should be spoken.
    func testReasoningIsNotReadAloud() {
        let raw = """
            dsh: reasoning:
            The user asked for a greeting. I'll reply briefly.
            你好！
            """
        XCTAssertEqual(DSHClient.cleanAnswer(raw), "你好！")

        let withBlank = "reasoning:\nthinking hard\n\nThe answer is 42.\n"
        XCTAssertEqual(DSHClient.cleanAnswer(withBlank), "The answer is 42.")
    }

    func testMarkdownNoiseIsStripped() {
        XCTAssertEqual(
            DSHClient.cleanAnswer("**Done.** Run `make`.\n```\ncode\n```"),
            "Done. Run make.\ncode")
        XCTAssertEqual(DSHClient.cleanAnswer("  plain answer  \n"), "plain answer")
    }

    /// `--patch examples/dsh-ollama.yml` must work outside the repo.
    func testPatchResolvesRelativeThenFromTheInstalledCopy() {
        let installed = URL(fileURLWithPath: "/home/u/.voicebridge/dsh")
        // Relative to the working directory, when it is there.
        XCTAssertEqual(
            DSHClient.resolvePatch(
                "examples/dsh-ollama.yml", cwd: "/repo", installed: installed,
                exists: { $0 == "/repo/examples/dsh-ollama.yml" }),
            "/repo/examples/dsh-ollama.yml")
        // Otherwise by file name in ~/.voicebridge/dsh/.
        XCTAssertEqual(
            DSHClient.resolvePatch(
                "examples/dsh-ollama.yml", cwd: "/elsewhere", installed: installed,
                exists: { $0 == "/home/u/.voicebridge/dsh/dsh-ollama.yml" }),
            "/home/u/.voicebridge/dsh/dsh-ollama.yml")
        // Neither: nil, so the CLI fails before listening.
        XCTAssertNil(
            DSHClient.resolvePatch(
                "missing.yml", cwd: "/x", installed: installed, exists: { _ in false }))
    }

    /// A failure must read as a sentence with a next step, not a path and a
    /// stack trace.
    func testDSHFailuresAreWordedForABubble() {
        let missingKey = """
            dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for provider route "deepseek-official"; store DEEPSEEK_API_KEY …
            """
        XCTAssertTrue(DSHClient.friendlyError(stderr: missingKey).contains("Local model"))

        let crash = """
            file:///Applications/…/index.js:4713
            \t\tthrow new Error(…)
            Error: dsh: failed to read overlay /x/dsh-ollama.yml: Error: ENOENT
                at loadOverlayPatches (file:///…)
            Node.js v24.21.0
            """
        let message = DSHClient.friendlyError(stderr: crash)
        XCTAssertTrue(message.contains("/x/dsh-ollama.yml"))
        XCTAssertFalse(message.contains("at loadOverlayPatches"))

        XCTAssertEqual(
            DSHClient.friendlyError(stderr: "dsh: INVALID_REQUEST: 400 bad thinking mode"),
            "DeepSeek Harness: INVALID_REQUEST: 400 bad thinking mode".replacingOccurrences(
                of: "INVALID_REQUEST: ", with: ""))
    }

    // MARK: - Discovery and the child environment (P0-1)

    /// A Finder-launched app has `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so PATH
    /// alone misses Homebrew, `~/.local/bin` and a per-user app install.
    func testDiscoveryLooksBeyondTheGuiPath() throws {
        XCTAssertEqual(
            DSHClient.locate(environment: ["PATH": "/usr/bin"]) {
                $0 == "/opt/homebrew/bin/dsh"
            }, "/opt/homebrew/bin/dsh", "Homebrew is not on a GUI's PATH")

        let perUser =
            ("~/Applications/" as NSString).expandingTildeInPath + "/DeepSeek Harness.app/"
            + DSHClient.launcherPathInBundle
        XCTAssertEqual(
            DSHClient.locate(environment: ["PATH": "/usr/bin"]) { $0 == perUser }, perUser,
            "an app dragged to ~/Applications is still found")

        let expanded = ("~/bin/dsh" as NSString).expandingTildeInPath
        XCTAssertEqual(
            DSHClient.locate(environment: ["VOICEBRIDGE_DSH": "~/bin/dsh"]) { $0 == expanded },
            expanded, "the override gets tilde expansion")

        XCTAssertEqual(
            DSHClient.locate(environment: ["PATH": "/usr/bin"], override: "/chosen/dsh") { _ in true
            },
            "/chosen/dsh", "an explicit choice wins")
    }

    /// The app must hand DSH a usable environment: a Finder launch has no
    /// shell exports, and the local patch needs `OLLAMA_API_KEY` to exist.
    func testTheChildEnvironmentCarriesPathAndTheOllamaKey() throws {
        let env = DSHClient.childEnvironment(base: ["PATH": "/usr/bin"])
        let path = try XCTUnwrap(env["PATH"])
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertEqual(env["OLLAMA_API_KEY"], "ollama")

        let kept = DSHClient.childEnvironment(base: ["OLLAMA_API_KEY": "kept"])
        XCTAssertEqual(kept["OLLAMA_API_KEY"], "kept", "a real value is never overwritten")
    }

    /// A read-only turn is what keeps DSH out of the user's files.
    func testAReadOnlyTurnPassesThePermissionMode() {
        XCTAssertEqual(
            DSHClient.arguments(
                prompt: "hi", profile: "headless", patches: [], permissionMode: "read-only"),
            ["--profile", "headless", "--permission-mode", "read-only", "--json", "hi"])
    }

    // MARK: - Progress (P1-3)

    func testProgressReadsTheEventStream() {
        XCTAssertEqual(DSHClient.progress(forLine: #"{"type":"thinking","text":"hmm"}"#), .thinking)
        XCTAssertEqual(DSHClient.progress(forLine: #"{"type":"text","text":"ok"}"#), .text("ok"))
        XCTAssertEqual(
            DSHClient.progress(
                forLine:
                    #"{"type":"tool_call","tool":"write","input":{"file_path":"/tmp/probe.txt"}}"#
            ),
            .tool(phrase: "Writing probe.txt…", name: "write"))
        XCTAssertNil(DSHClient.progress(forLine: "plain text, not JSON"))
    }

    func testToolPhrasesAreShortAndHuman() {
        XCTAssertEqual(
            DSHClient.phrase(forTool: "bash", input: ["command": "swift test"]),
            "Running swift test…")
        XCTAssertEqual(
            DSHClient.phrase(forTool: "read", input: ["path": "/a/b.txt"]), "Reading b.txt…")
        XCTAssertEqual(DSHClient.phrase(forTool: "mystery", input: [:]), "Using mystery…")
    }

    // MARK: - Failures carry a next step

    /// Electron writes a warning to stderr on every third-party launch; it must
    /// never be mistaken for the error.
    func testTheElectronNoiseIsNotTheErrorMessage() {
        let stderr = """
            [1111/231530.769256:ERROR:electron/shell/app/node_main.cc:154] Node.js environment variables are disabled because this process is invoked by other apps.
            dsh: AUTH: Authentication Fails, Your api key: ****test is invalid (request_id: 1)
            """
        let message = DSHClient.friendlyError(stderr: stderr)
        XCTAssertTrue(message.contains("rejected the API key"))
        XCTAssertFalse(message.contains("request_id"), "no internal ids in a chat bubble")
        XCTAssertFalse(message.contains("electron"))
    }

    /// A dead session id is recoverable, so it must be recognisable.
    func testAMissingSessionIsRecognisable() {
        XCTAssertEqual(
            DSHClient.kind(
                forStderr:
                    #"dsh: session "session-x" does not exist; omit --session-id to start a new Session"#
            ),
            .missingSession)
        XCTAssertEqual(
            DSHClient.kind(forStderr: "dsh: MISSING_CREDENTIAL: no API key"), .missingCredential)
        XCTAssertEqual(DSHClient.kind(forStderr: "boom"), .other)
    }
}
