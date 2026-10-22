import XCTest
@testable import VoiceBridgeCore

/// Tests for the whisper.cpp **server** backend (the interim step towards the
/// in-process backend: the model stays resident, so the live path does not
/// spawn a process per window).
final class WhisperServerBackendTests: XCTestCase {

    func testEnvironmentConfiguresTheServer() {
        let backend = WhisperServerBackend.fromEnvironment([
            "VOICEBRIDGE_WHISPER_SERVER": "127.0.0.1:8080",
        ])
        XCTAssertNotNil(backend)
        XCTAssertEqual(backend?.baseURL.absoluteString, "http://127.0.0.1:8080")

        let withScheme = WhisperServerBackend.fromEnvironment([
            "VOICEBRIDGE_WHISPER_SERVER": "http://127.0.0.1:9000",
        ])
        XCTAssertEqual(withScheme?.baseURL.absoluteString, "http://127.0.0.1:9000")
    }

    func testNoServerConfiguredMeansNoBackend() {
        XCTAssertNil(WhisperServerBackend.fromEnvironment([:]))
        XCTAssertNil(WhisperServerBackend.fromEnvironment([
            "VOICEBRIDGE_WHISPER_SERVER": "",
        ]))
    }

    func testMultipartBodyCarriesTheAudio() throws {
        let audio = Data("RIFF....WAVE".utf8)
        let body = try WhisperServerBackend.multipartBody(boundary: "BOUND",
                                                          filename: "in.wav",
                                                          audio: audio)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--BOUND\r\n"))
        XCTAssertTrue(text.contains("name=\"file\""))
        XCTAssertTrue(text.contains("filename=\"in.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        // The payload is in the body.
        XCTAssertTrue(body.range(of: audio) != nil)
    }

    func testServerJSONIsParsedIntoTimedSegments() throws {
        // The shape whisper.cpp's server returns.
        let json = """
        { "transcription": [
            { "text": " hello there",
              "offsets": { "from": 0, "to": 1500 } },
            { "text": " general kenobi",
              "offsets": { "from": 1500, "to": 4000 } }
        ] }
        """
        let meta = try XCTUnwrap(WhisperTranscriptParser.parseJSON(Data(json.utf8)))
        XCTAssertEqual(meta.segments.count, 2)
        XCTAssertEqual(meta.segments[0].text, "hello there")
        XCTAssertEqual(meta.segments[1].end, 4.0, accuracy: 0.001)
        XCTAssertTrue(meta.text.contains("hello there"))
    }

    func testLevelEstimateIsSane() {
        XCTAssertEqual(LiveSttSession.rms(of: []), 0)
        XCTAssertEqual(LiveSttSession.rms(of: [0.5, -0.5]), 0.5, accuracy: 0.001)
        XCTAssertEqual(LiveSttSession.rms(of: [0, 0, 0, 0]), 0)
    }
}
