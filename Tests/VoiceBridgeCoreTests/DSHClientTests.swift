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
}
