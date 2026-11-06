import XCTest

@testable import VoiceBridgeCore

/// Tests for the model catalog and the download controller.
///
/// The network tests are opt-in: set `VOICEBRIDGE_NETWORK_TESTS=1` to run
/// them (CI stays hermetic).
final class ModelCatalogTests: XCTestCase {

    func testCatalogCoversEveryWhisperModel() {
        for model in SttModel.allCases {
            XCTAssertNotNil(
                ModelCatalog.model(for: model),
                "the catalog should offer \(model.rawValue)")
        }
    }

    func testCatalogEntriesAreWellFormed() {
        for model in ModelCatalog.all {
            XCTAssertFalse(model.id.isEmpty)
            XCTAssertFalse(model.displayName.isEmpty)
            XCTAssertTrue(
                model.remoteURL.scheme == "https",
                "\(model.id) must be fetched over https")
            XCTAssertFalse(model.fileName.isEmpty)
            XCTAssertFalse(model.relativeDirectory.isEmpty)
        }
    }

    func testPiperVoicesCarryTheirConfig() {
        for voice in ModelCatalog.tts {
            XCTAssertEqual(
                voice.companions.count, 1,
                "\(voice.id) needs its .onnx.json next to the model")
            XCTAssertTrue(voice.companions[0].fileName.hasSuffix(".onnx.json"))
        }
    }

    /// Every entry must carry a real checksum and size.
    ///
    /// A `nil` checksum silently disabled the integrity check in
    /// `ModelDownloadController` — the plumbing was there, the data was not, so
    /// a truncated or substituted file installed "successfully". A stale
    /// `byteSize` is the same class of rot (the old `base` entry was off by 2×).
    func testEveryCatalogEntryCarriesAChecksumAndSize() {
        for model in ModelCatalog.all {
            let sha = model.sha256 ?? ""
            XCTAssertEqual(sha.count, 64, "\(model.id) must carry a SHA-256")
            XCTAssertTrue(
                sha.allSatisfy { $0.isHexDigit },
                "\(model.id) checksum is not hex")
            XCTAssertGreaterThan(model.byteSize, 0, "\(model.id) must carry a real byte size")
        }
    }

    /// The catalog ships a Chinese model for each engine, and the Chinese
    /// whisper fine-tune is saved under the name the backend looks for.
    func testChineseModelsArePresent() {
        let belle = ModelCatalog.model(for: .belleTurboZh)
        XCTAssertNotNil(belle, "the Belle Chinese whisper model must be in the catalog")
        XCTAssertEqual(belle?.fileName, "ggml-belle-large-v3-turbo-zh.bin")
        XCTAssertEqual(belle?.relativeDirectory, "whisper")
        // The repo serves a generic file name; the download URL points at it
        // while the on-disk name follows the whisper convention.
        XCTAssertEqual(belle?.remoteURL.lastPathComponent, "ggml-model.bin")

        let chineseVoice = ModelCatalog.tts.first { $0.id == "zh_CN-huayan-medium" }
        XCTAssertNotNil(chineseVoice, "the Chinese Piper voice must be in the catalog")
        XCTAssertFalse(
            chineseVoice?.companions.isEmpty ?? true,
            "a Piper voice needs its .onnx.json companion")
    }

    /// A non-200 answer must fail the download, not become an installed model.
    ///
    /// `URLSession` reports 404 and 500 as *successful* transfers, so without
    /// this check the error page is renamed to `ggml-*.bin`.
    func testANon200ResponseIsRejected() {
        let url = URL(string: "https://example.com/ggml-large-v3-turbo.bin")!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        XCTAssertNoThrow(try ModelDownloader.validate(response: ok))

        for status in [404, 403, 500] {
            let bad = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            XCTAssertThrowsError(try ModelDownloader.validate(response: bad), "HTTP \(status)") {
                error in
                guard case VoiceError.downloadFailed(_, let reason) = error else {
                    return XCTFail("expected .downloadFailed, got \(error)")
                }
                XCTAssertTrue(reason.contains("\(status)"), reason)
            }
        }

        // A non-HTTP response (or none at all) is not a status failure.
        XCTAssertNoThrow(try ModelDownloader.validate(response: nil))
    }

    func testDestinationLivesUnderTheModelRoot() {
        let root = ModelPaths(root: URL(fileURLWithPath: "/tmp/vb-models"))
        let whisper = ModelCatalog.model(for: .largeV3Turbo)!
        let destination = whisper.destination(in: root)
        XCTAssertTrue(destination.path.hasPrefix(root.root.path))
        XCTAssertEqual(destination.lastPathComponent, "ggml-large-v3-turbo.bin")

        let voice = ModelCatalog.tts[0]
        let voicePath = voice.destination(in: root)
        XCTAssertTrue(voicePath.path.contains("piper/voice"))
    }

    @MainActor
    func testIsInstalledNeedsTheCompanionFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-catalog-\(UUID().uuidString)")
        let paths = ModelPaths(root: root)
        let controller = ModelDownloadController()

        let voice = ModelCatalog.tts[0]
        XCTAssertFalse(controller.isInstalled(voice, in: paths))

        // The model alone is not enough: Piper needs the config next to it.
        let dir = root.appendingPathComponent("piper/voice", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0x00]).write(to: dir.appendingPathComponent(voice.fileName))
        XCTAssertFalse(controller.isInstalled(voice, in: paths))

        for companion in voice.companions {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(companion.fileName))
        }
        XCTAssertTrue(controller.isInstalled(voice, in: paths))
    }

    // MARK: - Network (opt-in)

    func testDownloadWorksOverTheNetwork() async throws {
        guard ProcessInfo.processInfo.environment["VOICEBRIDGE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set VOICEBRIDGE_NETWORK_TESTS=1 to run the network tests")
        }
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-download-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: destination) }

        let downloader = ModelDownloader()
        var lastProgress: ModelDownloader.Progress?
        for try await progress in await downloader.download(
            URL(
                string:
                    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
            )!,
            to: destination)
        {
            lastProgress = progress
        }
        XCTAssertNotNil(lastProgress)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let size =
            (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int)
            ?? 0
        XCTAssertGreaterThan(size, 0)
    }
}
