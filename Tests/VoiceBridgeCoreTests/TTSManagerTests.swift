import XCTest
@testable import VoiceBridgeCore

/// Tests for the TTS orchestration contract in `TTSManager`:
///
///   * an unavailable engine falls back to the built-in voice (and says so),
///   * an in-place engine is *not* asked to speak when playback is off,
///   * the cache slot is named after the engine's real file extension,
///   * a file-producing engine writes a file and reports it.
///
/// The engine is injected through `TTSManager.EngineFactory`, so these run
/// without Piper/Kokoro/edge-tts installed.
@MainActor
final class TTSManagerTests: XCTestCase {

    // MARK: - Doubles

    /// A fake engine that records what it was asked to do.
    final class FakeEngine: TTSBackend, @unchecked Sendable {
        let name: String
        let available: Bool
        let producesFile: Bool
        let fileExtension: String
        let requiresNet: Bool
        nonisolated(unsafe) var synthesizeCount = 0
        nonisolated(unsafe) var lastText: String?
        nonisolated(unsafe) var lastOutputPath: URL?

        init(name: String,
             available: Bool = true,
             producesFile: Bool = true,
             fileExtension: String = "wav",
             requiresNetwork: Bool = false) {
            self.name = name
            self.available = available
            self.producesFile = producesFile
            self.fileExtension = fileExtension
            self.requiresNet = requiresNetwork
        }

        var producesAudioFile: Bool { producesFile }
        var displayName: String { name }
        func isAvailable() -> Bool { available }
        var requiresNetwork: Bool { requiresNet }
        var preferredFileExtension: String { fileExtension }

        func synthesize(text: String, voice: String?, outputPath: URL) async throws -> URL {
            synthesizeCount += 1
            lastText = text
            lastOutputPath = outputPath
            if producesFile {
                // Write a byte so `hasAudioFile` is true.
                try Data([0x00]).write(to: outputPath)
            }
            return outputPath
        }
    }

    /// A config manager rooted in a throwaway directory.
    ///
    /// The settings file is a temp file too: without it the manager would
    /// *persist* the throwaway root into the user's real
    /// `~/Library/Application Support/VoiceBridge/config.json`.
    private func makeConfig() throws -> TTSConfigManager {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-tts-tests-\(UUID().uuidString)")
        let settings = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-tts-tests-\(UUID().uuidString).json")
        let config = TTSConfigManager(persistURL: settings)
        config.configureRoot(root)
        return config
    }

    // MARK: - Tests

    func testUnavailableEngineFallsBackToSystemVoice() async throws {
        let config = try makeConfig()
        let broken = FakeEngine(name: "Broken", available: false)
        let system = FakeEngine(name: "System", producesFile: false)

        let manager = TTSManager(config: config, pruneAfterWrite: false) { mode, _, _ in
            mode == .system ? system : broken
        }

        let result = try await manager.speak("hello", mode: .piper, voice: nil, play: false)

        XCTAssertTrue(result.fellBack)
        XCTAssertEqual(result.engineName, "System")
        XCTAssertEqual(result.requestedMode, .piper)
        XCTAssertFalse(result.hasAudioFile)
        XCTAssertTrue(result.statusLine.contains("fell back"))
    }

    func testNoFallbackThrowsWhenEngineUnavailable() async throws {
        let config = try makeConfig()
        let broken = FakeEngine(name: "Broken", available: false)
        let manager = TTSManager(config: config, pruneAfterWrite: false) { _, _, _ in broken }

        do {
            _ = try await manager.speak("hello", mode: .piper, play: false)
            XCTFail("expected engineUnavailable")
        } catch {
            guard case VoiceError.engineUnavailable = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testInPlaceEngineIsSilentWhenPlaybackIsOff() async throws {
        let config = try makeConfig()
        let system = FakeEngine(name: "System", producesFile: false)
        let manager = TTSManager(config: config, pruneAfterWrite: false) { _, _, _ in system }

        let result = try await manager.speak("hello", mode: .system, play: false)

        // The whole point: an in-place engine must not speak when the caller
        // asked for no playback (the CLI's --no-play path).
        XCTAssertEqual(system.synthesizeCount, 0)
        XCTAssertFalse(result.hasAudioFile)
    }

    func testFileEngineUsesItsOwnExtension() async throws {
        let config = try makeConfig()
        let edge = FakeEngine(name: "Edge", fileExtension: "mp3")
        let manager = TTSManager(config: config, pruneAfterWrite: false) { _, _, _ in edge }

        let result = try await manager.speak("hello", mode: .edgeTTS, play: false)

        XCTAssertEqual(edge.synthesizeCount, 1)
        XCTAssertEqual(edge.lastText, "hello")
        XCTAssertEqual(edge.lastOutputPath?.pathExtension, "mp3")
        XCTAssertEqual(result.url.pathExtension, "mp3")
        XCTAssertTrue(result.hasAudioFile)
    }

    func testOnlineEngineReportsAPrivacyNotice() async throws {
        let config = try makeConfig()
        let edge = FakeEngine(name: "Edge", fileExtension: "mp3", requiresNetwork: true)
        let manager = TTSManager(config: config, pruneAfterWrite: false) { _, _, _ in edge }

        let result = try await manager.speak("hello", mode: .edgeTTS, play: false)
        XCTAssertNotNil(result.privacyNotice)
        XCTAssertTrue(result.privacyNotice!.contains("online"))
    }

    func testOfflineEngineHasNoPrivacyNotice() async throws {
        let config = try makeConfig()
        let piper = FakeEngine(name: "Piper")
        let manager = TTSManager(config: config, pruneAfterWrite: false) { _, _, _ in piper }

        let result = try await manager.speak("hello", mode: .piper, play: false)
        XCTAssertNil(result.privacyNotice)
    }

    func testSpeechRunnerDeadlineIsBounded() {
        // A very long utterance gets a long (but finite) deadline; a short one
        // still gets a sane minimum.
        let short = SpeechRunner.deadline(for: "hi")
        let long = SpeechRunner.deadline(for: String(repeating: "word ", count: 10_000))
        XCTAssertGreaterThanOrEqual(short, 5)
        XCTAssertLessThanOrEqual(long, 300)
        XCTAssertGreaterThan(long, short)
    }
}
