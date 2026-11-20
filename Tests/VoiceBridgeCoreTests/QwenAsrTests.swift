import Foundation
import XCTest

@testable import VoiceBridgeCore

/// Qwen3-ASR support: the wire format, the server argv, the catalog entries,
/// and the two-tier routing.
///
/// These run without llama.cpp or a model on disk. `testLiveTranscription…`
/// is the one exception — it is skipped unless `VOICEBRIDGE_QWEN_LIVE=1` is
/// set, because it needs a real server.
final class QwenAsrTests: XCTestCase {

    // MARK: - The `language X<asr_text>` preamble

    func testTheLanguagePreambleIsStripped() {
        let raw = "language Chinese<asr_text>今天下午三点，我们在二楼会议室讨论下一季度的产品路线图。"
        let reply = QwenAsrBackend.splitPreamble(raw)
        XCTAssertEqual(reply.text, "今天下午三点，我们在二楼会议室讨论下一季度的产品路线图。")
        XCTAssertEqual(reply.language, "chinese")
    }

    func testAnEnglishPreambleIsStripped() {
        let reply = QwenAsrBackend.splitPreamble(
            "language English<asr_text>Schedule a follow-up with the design team.")
        XCTAssertEqual(reply.text, "Schedule a follow-up with the design team.")
        XCTAssertEqual(reply.language, "english")
    }

    func testSilenceReportsNoLanguageAndNoText() {
        // Qwen writes "language None<asr_text>" for a clip with no speech.
        let reply = QwenAsrBackend.splitPreamble("language None<asr_text>")
        XCTAssertEqual(reply.text, "")
        XCTAssertNil(reply.language, "‘None’ is the absence of a language, not one")
    }

    func testAResponseWithoutTheMarkerIsKeptWhole() {
        // A future llama.cpp may stop emitting the preamble. Dropping text we
        // do not recognise would be worse than showing it.
        let reply = QwenAsrBackend.splitPreamble("  你好，世界。 ")
        XCTAssertEqual(reply.text, "你好，世界。")
        XCTAssertNil(reply.language)
    }

    func testOnlyTheFirstMarkerIsConsumed() {
        let reply = QwenAsrBackend.splitPreamble(
            "language Chinese<asr_text>他说<asr_text>不是标签，是内容。")
        XCTAssertEqual(reply.text, "他说<asr_text>不是标签，是内容。")
    }

    // MARK: - Response parsing

    func testTheDoneEventParses() throws {
        let json = """
            {"type":"transcript.text.done","text":"language Chinese<asr_text>你好。",
             "usage":{"type":"tokens","input_tokens":10,"output_tokens":2,"total_tokens":12}}
            """
        let reply = QwenAsrBackend.parseResponse(Data(json.utf8))
        XCTAssertEqual(reply.text, "你好。")
        XCTAssertEqual(reply.language, "chinese")
    }

    func testAnSSEBodyParsesToItsLastFullText() {
        let sse = """
            data: {"type":"transcript.text.delta","delta":"language"}

            data: {"type":"transcript.text.delta","delta":" Chinese"}

            data: {"type":"transcript.text.done","text":"language Chinese<asr_text>完成了。"}

            """
        let reply = QwenAsrBackend.parseResponse(Data(sse.utf8))
        XCTAssertEqual(reply.text, "完成了。")
    }

    func testGarbageYieldsEmptyTextNotACrash() {
        let reply = QwenAsrBackend.parseResponse(Data("<html>502 Bad Gateway</html>".utf8))
        XCTAssertEqual(reply.text, "")
    }

    func testTheMultipartBodyNamesTheFileAndTheModel() throws {
        let body = try QwenAsrBackend.multipartBody(
            boundary: "XYZ", filename: "clip.wav", audio: Data([1, 2, 3]))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"clip.wav\""))
        XCTAssertTrue(text.contains("qwen3-asr"))
        XCTAssertTrue(text.hasSuffix("--XYZ--\r\n"))
    }

    // MARK: - Server argv

    func testTheServerBindsLoopbackOnly() {
        let args = QwenAsrServer.arguments(
            model: "/m.gguf", mmproj: "/mm.gguf", port: 8090, contextSize: 4096, parallel: 2)
        XCTAssertEqual(args.first, "-m")
        XCTAssertTrue(args.contains("--mmproj"))
        XCTAssertTrue(args.contains("/mm.gguf"))
        // The audio projector is not optional: without it every request fails.
        let host = args.firstIndex(of: "--host").map { args[$0 + 1] }
        XCTAssertEqual(host, "127.0.0.1", "never 0.0.0.0 — this API has no auth")
        let ctx = args.firstIndex(of: "--ctx-size").map { args[$0 + 1] }
        XCTAssertEqual(ctx, "4096")
    }

    // MARK: - Locating llama-server

    func testTheSearchOrderPrefersTheOverride() {
        let paths = QwenAsrServer.candidates(
            environment: ["PATH": "/usr/bin", "VOICEBRIDGE_LLAMA_SERVER": "/env/llama-server"],
            override: "/chosen/llama-server")
        XCTAssertEqual(paths.first, "/chosen/llama-server")
        XCTAssertEqual(paths.dropFirst().first, "/env/llama-server")
        XCTAssertTrue(paths.contains("/usr/bin/llama-server"))
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/llama-server"))
    }

    func testASelfInstalledReleaseIsFound() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-qwen-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // An empty PATH and no override: only the explicit fallbacks remain.
        let found = try? QwenAsrServer.locateExecutable(
            environment: ["PATH": ""], override: nil,
            isExecutable: { $0 == "/opt/homebrew/bin/llama-server" })
        XCTAssertEqual(found, "/opt/homebrew/bin/llama-server")
    }

    func testAMissingServerIsAnActionableError() {
        XCTAssertThrowsError(
            try QwenAsrServer.locateExecutable(
                environment: ["PATH": ""], override: nil, isExecutable: { _ in false })
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("llama"), "got: \(message)")
        }
    }

    func testOnlyExecutablesAreTriedAndEachOnce() {
        let tried = QwenAsrServer.executables(
            environment: ["PATH": "/a:/a:/b"], override: nil,
            isExecutable: { $0.hasSuffix("/a/llama-server") || $0.hasSuffix("/b/llama-server") })
        XCTAssertEqual(tried, ["/a/llama-server", "/b/llama-server"])
    }

    // MARK: - Catalog

    func testBothTiersAreInTheCatalogWithAChecksumAndAProjector() {
        XCTAssertEqual(ModelCatalog.qwen.count, 2)
        for entry in ModelCatalog.qwen {
            XCTAssertEqual(entry.kind, .sttQwen)
            XCTAssertNotNil(entry.sha256, "\(entry.id) has no checksum")
            XCTAssertGreaterThan(entry.byteSize, 0)
            XCTAssertEqual(
                entry.companions.count, 1,
                "\(entry.id) must ship its mmproj audio projector")
            XCTAssertTrue(entry.companions[0].fileName.hasPrefix("mmproj-"))
        }
    }

    func testTheCatalogEntryLandsInTheQwenDirectory() {
        let root = ModelPaths(root: URL(fileURLWithPath: "/tmp/vb-models/tts"))
        let entry = ModelCatalog.qwen[0]
        let destination = entry.destination(in: root)
        XCTAssertEqual(destination.deletingLastPathComponent().path, root.qwen3Dir.path)
        XCTAssertFalse(destination.path.contains(".."), "the path must be normalized")
    }

    func testTheCatalogFileNamesMatchWhatTheServerOpens() {
        for tier in QwenAsrTier.allCases {
            let entry = ModelCatalog.qwen.first { $0.fileName == tier.modelFileName }
            XCTAssertNotNil(entry, "\(tier.rawValue) has no catalog entry")
            XCTAssertEqual(entry?.companions.first?.fileName, tier.mmprojFileName)
        }
    }

    // MARK: - Settings

    func testSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "vb-qwen-tests-\(UUID().uuidString)")!
        let settings = SttEngineSettings(
            kind: .qwen3, qwenTier: .fast, qwenFinalTier: .accurate)
        settings.save(to: defaults)
        XCTAssertEqual(SttEngineSettings.load(from: defaults), settings)
    }

    func testDefaultsToWhisperWhenNothingIsStored() {
        let defaults = UserDefaults(suiteName: "vb-qwen-tests-\(UUID().uuidString)")!
        XCTAssertEqual(SttEngineSettings.load(from: defaults).kind, .whisperCLI)
    }

    func testTwoTiersOnlyWhenTheyDiffer() {
        let same = SttEngineSettings(kind: .qwen3, qwenTier: .accurate, qwenFinalTier: .accurate)
        XCTAssertFalse(same.usesTwoTiers)
        let two = SttEngineSettings(kind: .qwen3, qwenTier: .fast, qwenFinalTier: .accurate)
        XCTAssertTrue(two.usesTwoTiers)
        XCTAssertEqual(two.finalTierOrFast, .accurate)
        let one = SttEngineSettings(kind: .qwen3, qwenTier: .fast)
        XCTAssertFalse(one.usesTwoTiers)
        XCTAssertEqual(one.finalTierOrFast, .fast)
    }

    func testWhisperEnginesDefaultToNoSecondTier() {
        XCTAssertFalse(SttEngineSettings(kind: .whisperCLI).usesTwoTiers)
    }

    func testQwenIsProvablyLocalAndTheWhisperServerIsNot() {
        XCTAssertTrue(SttEngineKind.qwen3.isProvablyLocal)
        XCTAssertTrue(SttEngineKind.whisperCLI.isProvablyLocal)
        // Its URL comes from the environment and may name another machine.
        XCTAssertFalse(SttEngineKind.whisperServer.isProvablyLocal)
    }

    // MARK: - Two-tier routing

    func testPartialsGoToTheFastModelAndFinalsToTheAccurateOne() async throws {
        let fast = SpyBackend(text: "fast")
        let accurate = SpyBackend(text: "accurate")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-tier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let adapter = TieredWhisperAdapter(
            partialBackend: fast, finalBackend: accurate, scratchDir: dir)
        let samples = [Float](repeating: 0.01, count: 16_000)

        let partial = try await adapter.transcribe(
            samples: samples, sampleRate: 16_000, startTime: 0,
            model: "whatever", language: "zh", hint: .partial)
        let final = try await adapter.transcribe(
            samples: samples, sampleRate: 16_000, startTime: 0,
            model: "whatever", language: "zh", hint: .final)

        XCTAssertEqual(partial.first?.text, "fast")
        XCTAssertEqual(final.first?.text, "accurate")
        XCTAssertEqual(fast.calls, 1)
        XCTAssertEqual(accurate.calls, 1)
    }

    // MARK: - Live (opt-in)

    /// Hits a real llama-server. Enable with:
    ///
    ///     VOICEBRIDGE_QWEN_LIVE=1 swift test --filter testLive
    ///
    /// It starts (and stops) its own server through `QwenAsrServer`, so it also
    /// covers the launch, health-check and shutdown path.
    func testLiveTranscriptionThroughTheServer() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["VOICEBRIDGE_QWEN_LIVE"] == "1",
            "set VOICEBRIDGE_QWEN_LIVE=1 to run against a real llama-server")

        let paths = ModelPaths.fromEnvironment()
        let server = QwenAsrServer(
            configuration: .init(modelDirectory: paths.qwen3Dir, idleTimeout: 30))
        defer { Task { await server.stopAll() } }

        // A 1-second 440 Hz tone is not speech; the contract we assert is the
        // *shape* of the answer (it returns, without a preamble), not its text.
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-tone-\(UUID().uuidString).wav")
        let samples = (0..<16_000).map { sin(Float($0) / 16_000 * 440 * 2 * .pi) * 0.1 }
        try WAVWriter.write(samples: samples, sampleRate: 16_000, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let url = try await server.baseURL(for: .fast)
        let backend = QwenAsrBackend(baseURL: url, tier: .fast)
        let result = try await backend.transcribe(
            audio: wav, language: nil, model: .tiny, useTimestamps: false)

        XCTAssertFalse(result.text.contains("<asr_text>"), "the preamble must be gone")
        XCTAssertEqual(result.engineLabel, "Qwen3-ASR 0.6B")
        XCTAssertNil(result.model, "no whisper checkpoint ran, so `model` must be empty")
        XCTAssertGreaterThan(result.wallClockSeconds, 0)

        let tiers = await server.runningTiers()
        XCTAssertEqual(tiers, [.fast])
    }
}

/// Records calls so the routing test can see which backend ran.
private final class SpyBackend: WhisperBackend, @unchecked Sendable {
    let text: String
    private let lock = NSLock()
    private var count = 0

    init(text: String) { self.text = text }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func transcribe(
        audio: URL, language: String?, model: SttModel, useTimestamps: Bool
    ) async throws -> Transcription {
        lock.lock()
        count += 1
        lock.unlock()
        return Transcription(
            text: text, language: language ?? "auto", model: model,
            durationSeconds: 1, realtimeFactor: 0)
    }
}
