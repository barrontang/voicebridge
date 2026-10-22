import XCTest
@testable import VoiceBridgeCore

/// Tests for the Fish Audio Drama 3 engine (a served, multi-speaker TTS
/// model behind an OpenAI-compatible `/v1/audio/speech` endpoint).
final class FishAudioTests: XCTestCase {

    // MARK: - Configuration

    func testTheEngineNeedsAServer() {
        XCTAssertNil(FishAudioBackend.fromEnvironment([:]),
                      "without a server the engine is not configured")
        let backend = FishAudioBackend.fromEnvironment([
            "VOICEBRIDGE_FISH_TTS": "http://127.0.0.1:8000",
        ])
        XCTAssertNotNil(backend)
        XCTAssertEqual(backend?.baseURL.absoluteString, "http://127.0.0.1:8000")
        XCTAssertTrue(backend?.isAvailable() == true)
    }

    func testATrailingSlashIsTrimmed() {
        let backend = FishAudioBackend.fromEnvironment([
            "VOICEBRIDGE_FISH_TTS": "http://127.0.0.1:8000/",
        ])
        XCTAssertEqual(backend?.baseURL.absoluteString, "http://127.0.0.1:8000")
    }

    func testTheReferenceClipIsReadFromTheEnvironment() {
        let backend = FishAudioBackend.fromEnvironment([
            "VOICEBRIDGE_FISH_TTS": "http://127.0.0.1:8000",
            "VOICEBRIDGE_FISH_REFERENCE": "/tmp/ref.wav",
            "VOICEBRIDGE_FISH_REFERENCE_TEXT": "the reference transcript",
        ])
        XCTAssertEqual(backend?.referencePath, "/tmp/ref.wav")
        XCTAssertEqual(backend?.referenceText, "the reference transcript")
    }

    // MARK: - The request

    func testTheRequestCarriesTheText() throws {
        let body = try FishAudioBackend.requestBody(text: "Hello there.",
                                                   referencePath: nil,
                                                   referenceText: nil)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["input"] as? String, "Hello there.")
        // `text` is what the Drama 3 examples use; `input` is the
        // OpenAI-compatible field. Both are sent.
        XCTAssertEqual(json?["text"] as? String, "Hello there.")
        XCTAssertEqual(json?["response_format"] as? String, "wav")
        XCTAssertNil(json?["references"])
    }

    func testTheRequestCarriesTheReferenceForCloning() throws {
        let body = try FishAudioBackend.requestBody(text: "Cloned.",
                                                   referencePath: "/tmp/ref.wav",
                                                   referenceText: "the reference transcript")
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let references = json?["references"] as? [[String: Any]]
        XCTAssertEqual(references?.count, 1)
        XCTAssertEqual(references?.first?["audio_path"] as? String, "/tmp/ref.wav")
        XCTAssertEqual(references?.first?["text"] as? String, "the reference transcript")
    }

    func testTheRequestOmitsAnEmptyReference() throws {
        let body = try FishAudioBackend.requestBody(text: "Hi.",
                                                   referencePath: "",
                                                   referenceText: nil)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNil(json?["references"])
    }

    // MARK: - The mode

    func testFishAudioIsAnOnlineEngine() {
        XCTAssertTrue(TTSMode.fishAudio.isOnline)
        XCTAssertTrue(TTSMode.edgeTTS.isOnline)
        XCTAssertFalse(TTSMode.piper.isOnline)
        XCTAssertFalse(TTSMode.kokoro.isOnline)
        XCTAssertFalse(TTSMode.system.isOnline)
    }

    /// A settings file written by a newer build (an engine this build does
    /// not know) must not wipe the user's configuration.
    func testAnUnknownEngineInTheSettingsFallsBackInsteadOfFailing() throws {
        let json = """
        { "schemaVersion": 99, "mode": "Some Future Engine" }
        """
        struct Cfg: Decodable { let mode: TTSMode? }
        let cfg = try JSONDecoder().decode(Cfg.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.mode, .piper, "an unknown engine must not break the config")
    }
}
