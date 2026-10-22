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
        XCTAssertTrue(backend?.isLocal == true)
        // A local server only counts as available when something answers.
        // (Whether one happens to run on the test machine is not asserted.)
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
        // mlx-audio's spelling of the same information.
        XCTAssertEqual(json?["ref_audio"] as? String, "/tmp/ref.wav")
        XCTAssertEqual(json?["ref_text"] as? String, "the reference transcript")
    }

    func testTheRequestNamesTheModelWhenOneIsConfigured() throws {
        let body = try FishAudioBackend.requestBody(text: "Hi.",
                                                   modelID: "mlx-community/fish-audio-drama-3-4bit",
                                                   referencePath: nil,
                                                   referenceText: nil)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "mlx-community/fish-audio-drama-3-4bit")
    }

    /// mlx-audio answers a bad request with a JSON error page; the player must
    /// never be handed that as if it were a WAV.
    func testAnErrorPageIsNotMistakenForAudio() {
        XCTAssertTrue(FishAudioBackend.looksLikeAudio(Data("RIFF....WAVEfmt ".utf8)))
        XCTAssertTrue(FishAudioBackend.looksLikeAudio(Data([0x49, 0x44, 0x33, 0x04])))
        XCTAssertFalse(FishAudioBackend.looksLikeAudio(Data(#"{"detail":"boom"}"#.utf8)))
        XCTAssertFalse(FishAudioBackend.looksLikeAudio(Data("<html>nope</html>".utf8)))
        XCTAssertFalse(FishAudioBackend.looksLikeAudio(Data()))
    }

    func testADeadLocalServerHasAnActionableHint() {
        let local = URL(string: "http://127.0.0.1:8000") ?? URL(fileURLWithPath: "/")
        let hint = FishAudioBackend.hint(for: URLError(.cannotConnectToHost), baseURL: local)
        XCTAssertTrue(hint.contains("start-drama3-mlx.sh"), hint)

        let remote = URL(string: "http://192.0.2.10:8000") ?? URL(fileURLWithPath: "/")
        let remoteHint = FishAudioBackend.hint(for: URLError(.cannotConnectToHost), baseURL: remote)
        XCTAssertTrue(remoteHint.contains("192.0.2.10"), remoteHint)
        XCTAssertFalse(remoteHint.contains("start-drama3-mlx.sh"), remoteHint)
    }

    func testTheRequestOmitsAnEmptyReference() throws {
        let body = try FishAudioBackend.requestBody(text: "Hi.",
                                                   referencePath: "",
                                                   referenceText: nil)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertNil(json?["references"])
    }

    // MARK: - The local MLX checkpoint

    func testADownloadedCheckpointSelectsTheLocalEngine() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCheckpoint(root: root, shardBytes: 19_000_000_000)

        let backend = FishAudioBackend.fromEnvironment([:], modelRoot: root)
        XCTAssertNotNil(backend, "a complete checkpoint is enough — no env var needed")
        XCTAssertEqual(backend?.baseURL.absoluteString, FishAudioBackend.defaultLocalURL)
        XCTAssertTrue(backend?.isLocal == true)
        // The server gets a path, not a repo id: it loads from disk, offline.
        XCTAssertEqual(backend?.modelID,
                       FishAudioBackend.localModelDirectory(root: root).path)
        // A local server keeps the text on this Mac, so no consent sheet.
        XCTAssertFalse(backend?.requiresNetwork == true)
        XCTAssertTrue(backend?.displayName.contains("local") == true)
    }

    func testAPartialDownloadDoesNotSelectTheLocalEngine() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // config.json and the codec arrive first; the weights do not.
        try makeCheckpoint(root: root, shardBytes: 1_000_000_000)
        XCTAssertFalse(FishAudioBackend.localModelExists(root: root))
        XCTAssertNil(FishAudioBackend.fromEnvironment([:], modelRoot: root))
    }

    func testAnExplicitServerWinsOverTheLocalCheckpoint() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCheckpoint(root: root, shardBytes: 19_000_000_000)

        let backend = FishAudioBackend.fromEnvironment(
            ["VOICEBRIDGE_FISH_TTS": "http://192.0.2.10:9000"],
            modelRoot: root)
        XCTAssertEqual(backend?.baseURL.host, "192.0.2.10")
        XCTAssertFalse(backend?.isLocal == true)
        XCTAssertTrue(backend?.requiresNetwork == true, "a remote server needs consent")
    }

    /// Changing the local port (`VOICEBRIDGE_FISH_TTS=http://127.0.0.1:8001`)
    /// must still tell mlx-audio which checkpoint to load.
    func testAnExplicitLocalPortStillNamesTheCheckpoint() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeCheckpoint(root: root, shardBytes: 19_000_000_000)

        let backend = FishAudioBackend.fromEnvironment(
            ["VOICEBRIDGE_FISH_TTS": "http://127.0.0.1:8001"],
            modelRoot: root)
        XCTAssertEqual(backend?.baseURL.port, 8001)
        XCTAssertEqual(backend?.modelID,
                       FishAudioBackend.localModelDirectory(root: root).path)
    }

    func testTheModelCanBeOverriddenForALocalServer() {
        let env = ["VOICEBRIDGE_FISH_TTS": "http://127.0.0.1:8000",
                   "VOICEBRIDGE_FISH_MODEL": "mlx-community/fish-audio-drama-3-8bit"]
        let backend = FishAudioBackend.fromEnvironment(env)
        XCTAssertEqual(backend?.modelID, "mlx-community/fish-audio-drama-3-8bit")
    }

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-fish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A checkpoint directory with a sparse shard of the requested size (no
    /// real disk use — APFS holes).
    private func makeCheckpoint(root: URL, shardBytes: UInt64) throws {
        let dir = FishAudioBackend.localModelDirectory(root: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data([0]).write(to: dir.appendingPathComponent("codec.safetensors"))
        let shard = dir.appendingPathComponent("model-00001.safetensors")
        FileManager.default.createFile(atPath: shard.path, contents: nil)
        let handle = try FileHandle(forWritingTo: shard)
        try handle.truncate(atOffset: shardBytes)
        try handle.close()
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
