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
                "--profile", "headless", "--patch", "/a.yml", "--patch", "/b.yml",
                "今天天气怎么样？ \"quoted\"",
            ])
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
