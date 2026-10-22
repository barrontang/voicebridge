import XCTest
@testable import VoiceBridgeCore

/// Tests for the settings file: schema versioning, forward migration, the
/// custom model root, and the "a newer build wrote this" guard.
///
/// Every test points the manager at a temp file (`init(persistURL:)`) so the
/// developer's real `~/Library/Application Support/VoiceBridge/config.json`
/// is never read or written.
@MainActor
final class ConfigPersistenceTests: XCTestCase {

    private func tempConfigURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-config-\(UUID().uuidString).json")
    }

    // MARK: - Round trip

    func testSettingsSurviveAReload() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let first = TTSConfigManager(persistURL: url)
        first.selectedMode = .kokoro
        first.selectedModelFile = "af_bella"
        first.selectedSttModel = .small
        XCTAssertNotNil(first.persist())

        let second = TTSConfigManager(persistURL: url)
        XCTAssertEqual(second.selectedMode, .kokoro)
        XCTAssertEqual(second.selectedModelFile, "af_bella")
        XCTAssertEqual(second.selectedSttModel, .small)
    }

    func testCustomModelRootIsPersistedAndRestored() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-models-\(UUID().uuidString)")

        let first = TTSConfigManager(persistURL: url)
        first.configureRoot(root)
        XCTAssertEqual(first.modelRoot.path, root.path)
        // Every engine layout follows the root.
        XCTAssertEqual(first.paths.whisperDir.path,
                       root.appendingPathComponent("whisper").path)
        XCTAssertEqual(first.paths.piperVoiceDir.path,
                       root.appendingPathComponent("piper")
                           .appendingPathComponent("voice").path)

        let second = TTSConfigManager(persistURL: url)
        XCTAssertEqual(second.modelRoot.path, root.path)
        XCTAssertEqual(second.paths.root.path, root.path)
    }

    // MARK: - Migration

    func testPreVersionedConfigIsMigratedForward() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // A pre-versioning record (no `schemaVersion`).
        let legacy = """
        { "mode": "Kokoro-82M (local)", "voice": "af_bella" }
        """
        try Data(legacy.utf8).write(to: url)

        let manager = TTSConfigManager(persistURL: url)
        XCTAssertEqual(manager.selectedMode, .kokoro)
        XCTAssertEqual(manager.selectedModelFile, "af_bella")

        // The migration is written back immediately, not "the next time the
        // user changes a setting".
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, TTSConfigManager.schemaVersion)
    }

    func testConfigFromANewerBuildIsNotOverwritten() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let future = """
        { "schemaVersion": 999, "mode": "Edge TTS (online)" }
        """
        try Data(future.utf8).write(to: url)

        let manager = TTSConfigManager(persistURL: url)
        // We still read what we understand...
        XCTAssertEqual(manager.selectedMode, .edgeTTS)
        // ...but we must not clobber the newer file.
        manager.selectedModelFile = "en-US-AriaNeural"
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["schemaVersion"] as? Int, 999)
        XCTAssertNil(json?["voice"])
    }

    // MARK: - Robustness

    func testCorruptConfigIsIgnoredNotFatal() throws {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{not json at all".utf8).write(to: url)

        // A corrupt file must not stop the app from starting.
        let manager = TTSConfigManager(persistURL: url)
        XCTAssertEqual(manager.selectedMode, .piper)   // the default
    }

    /// The CLI's `--engine` is a one-shot choice. It must not rewrite the
    /// engine the user picked in the app (`voicebridge-cli tts --engine fish`
    /// used to persist "Fish Audio" into the real settings file).
    func testAOneShotSessionNeverWritesTheSettings() {
        let url = tempConfigURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = TTSConfigManager(persistURL: url, persistChanges: false)
        manager.selectedMode = .fishAudio
        manager.selectedModelFile = "a-reference.wav"
        manager.selectedSttModel = .tiny

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "a one-shot session must not create a settings file")
        XCTAssertNil(manager.persist())
    }
}
