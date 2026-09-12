import XCTest
@testable import VoiceBridgeCore

/// Smoke tests for the pure-logic parts of the core. Audio/shell parts are
/// integration-tested by `voicebridge-cli ping`/`stt`/`tts`, not unit-tested
/// here (they need a mic and an installed binary).
final class CoreTests: XCTestCase {
    func testSttModelLabelsAndFilenames() {
        XCTAssertEqual(SttModel.largeV3Turbo.ggmlFilename, "ggml-large-v3-turbo.bin")
        XCTAssertTrue(SttModel.largeV3Turbo.label.contains("RECOMMENDED"))
        // tiny, base, small, medium, large-v3-turbo, large-v3
        XCTAssertEqual(SttModel.allCases.count, 6)
        XCTAssertEqual(SttModel.largeV3.ggmlFilename, "ggml-large-v3.bin")
      }

     func testTTSModes() {
        XCTAssertEqual(TTSMode.piper.rawValue, "Piper (local, DEFAULT)")
        XCTAssertEqual(TTSMode.system.rawValue, "Built-in (offline)")
       }

     func testURLHelpers() {
        // appendingIsDirectory() sets the URL's *directory flag* (not a
        // filesystem query), so assert hasDirectoryPath.
        let url = URL(fileURLWithPath: "/a/b/c").appendingIsDirectory()
        XCTAssertTrue(url.hasDirectoryPath)

        XCTAssertEqual("en_US-lessac-medium.onnx".lastPathComponentWithoutSuffix,
                       "en_US-lessac-medium")
       }

     func testVoiceErrorFormatting() {
        let e = VoiceError.modelMissing(model: "ggml-large-v3-turbo.bin", directory: "/tmp/m")
        XCTAssertNotNil(e.errorDescription)
        XCTAssertTrue(e.errorDescription!.contains("ggml-large-v3-turbo.bin"))
       }
}
