import XCTest

@testable import VoiceBridgeCore

/// The contextual corrector: the diff that measures a change, the policy that
/// vets it, and the local-model client that produces it.
///
/// The model itself is never called from a test — a corrector is a language
/// model, so what must be pinned down is the *guard rail*, not its opinion.
final class CorrectionTests: XCTestCase {

    // MARK: - WordDiff

    func testASingleWordFixIsOneChange() {
        let diff = WordDiff.compare("the meeting is at tree", "the meeting is at three")
        XCTAssertEqual(diff.total, 5)
        XCTAssertEqual(diff.changed, 1)
        XCTAssertEqual(diff.ratio, 0.2, accuracy: 0.001)
    }

    func testIdenticalTextChangesNothing() {
        let diff = WordDiff.compare("hello world", "hello world")
        XCTAssertEqual(diff.changed, 0)
        XCTAssertEqual(diff.ratio, 0)
    }

    /// Chinese has no spaces: a char-based diff is the only meaningful one.
    func testChineseComparesPerCharacter() {
        let diff = WordDiff.compare("今天天气很好", "今天天气很号")
        XCTAssertEqual(diff.total, 6)
        XCTAssertEqual(diff.changed, 1)
        XCTAssertLessThan(diff.ratio, 0.2)
    }

    func testARewriteTouchesMostOfTheSentence() {
        let diff = WordDiff.compare("the cat sat on the mat", "a dog was sleeping outside")
        XCTAssertGreaterThan(diff.ratio, 0.5)
    }

    // MARK: - Policy

    func testAHomophoneFixIsAccepted() {
        let decision = CorrectionPolicy.evaluate(
            original: "the meeting is at tree",
            corrected: "the meeting is at three")
        XCTAssertTrue(decision.accepted, decision.reason)
    }

    func testARewriteIsRejected() {
        let decision = CorrectionPolicy.evaluate(
            original: "the cat sat on the mat",
            corrected: "a dog was sleeping outside")
        XCTAssertFalse(decision.accepted)
    }

    func testATranslationIsRejected() {
        let decision = CorrectionPolicy.evaluate(
            original: "the meeting is at three",
            corrected: "会议在三点")
        XCTAssertFalse(decision.accepted)
    }

    func testUnchangedOrEmptyOutputIsRejected() {
        XCTAssertFalse(
            CorrectionPolicy.evaluate(original: "hello", corrected: "hello").accepted)
        XCTAssertFalse(CorrectionPolicy.evaluate(original: "hello", corrected: " ").accepted)
    }

    func testAGrownSentenceBeyondTheLengthBudgetIsRejected() {
        let decision = CorrectionPolicy.evaluate(
            original: "yes",
            corrected: "yes, that is absolutely correct and I agree with you completely")
        XCTAssertFalse(decision.accepted)
    }

    func testAChineseCharacterFixIsAccepted() {
        let decision = CorrectionPolicy.evaluate(
            original: "今天天气很好", corrected: "今天天气很号")
        XCTAssertTrue(decision.accepted, decision.reason)
    }

    // MARK: - Client parsing

    func testTheClientReadsTheAssistantContent() throws {
        let json = """
            {"message":{"role":"assistant","content":"the meeting is at three"},"done":true}
            """
        let text = LocalLLMCorrector.parse(Data(json.utf8))
        XCTAssertEqual(text, "the meeting is at three")
    }

    /// A thinking model puts its reasoning in a sibling field; the answer is
    /// `content`. It also likes code fences and quotes.
    func testTheClientStripsFencesAndQuotes() throws {
        let fenced = """
            {"message":{"content":"```text\\nthe meeting is at three\\n```"}}
            """
        XCTAssertEqual(LocalLLMCorrector.parse(Data(fenced.utf8)), "the meeting is at three")

        let quoted = """
            {"message":{"content":"\\"the meeting is at three\\""}}
            """
        XCTAssertEqual(LocalLLMCorrector.parse(Data(quoted.utf8)), "the meeting is at three")
    }

    func testAnEmptyOrMalformedResponseIsNil() {
        XCTAssertNil(
            LocalLLMCorrector.parse(Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8)))
        XCTAssertNil(LocalLLMCorrector.parse(Data("not json".utf8)))
        XCTAssertNil(LocalLLMCorrector.parse(Data(#"{"choices":[]}"#.utf8)))
    }

    func testThePromptCarriesContextAndTheSentence() {
        let message = LocalLLMCorrector.userMessage(
            sentence: "the meeting is at tree",
            context: ["we should reschedule", "the meeting is at three"])
        XCTAssertTrue(message.contains("we should reschedule"))
        XCTAssertTrue(message.contains("the meeting is at tree"))
        XCTAssertTrue(message.contains("(none)") == false)

        XCTAssertTrue(
            LocalLLMCorrector.userMessage(sentence: "hello", context: []).contains("(none)"))
    }

    // MARK: - Settings

    /// The correction settings survive a relaunch and default to off.
    @MainActor
    func testCorrectionSettingsArePersisted() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-correction-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = TTSConfigManager(persistURL: url)
        XCTAssertFalse(first.correctionEnabled, "contextual correction is opt-in")
        XCTAssertEqual(first.correctionModel, LocalLLMCorrector.defaultModel)

        first.correctionEnabled = true
        first.correctionModel = "qwen3.5:4b"
        XCTAssertNotNil(first.persist())

        let second = TTSConfigManager(persistURL: url)
        XCTAssertTrue(second.correctionEnabled)
        XCTAssertEqual(second.correctionModel, "qwen3.5:4b")
    }
}
