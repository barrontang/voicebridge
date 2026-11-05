import XCTest

@testable import VoiceBridgeCore

/// Regression tests for the model-download path.
///
/// The bug this guards against: a model downloads perfectly well, but the app
/// never rescans, so the front page keeps saying "no whisper models on disk"
/// until the app is restarted.
///
/// The transport is faked (`FakeFetcher`), so these run offline and
/// deterministically.
final class ModelDownloadTests: XCTestCase {

    /// Writes a fake "model" into the destination.
    private struct FakeFetcher: ModelFetcher {
        var shouldFail = false
        var written: [URL] = []

        func fetch(
            _ remote: URL,
            to destination: URL,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            if shouldFail { throw URLError(.networkConnectionLost) }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            progress(0.5)
            try Data("fake model".utf8).write(to: destination)
            progress(1.0)
        }
    }

    /// Wait until the controller is done (its status no longer says
    /// "Downloading …").
    @MainActor
    private func waitForDownload(
        _ controller: ModelDownloadController,
        timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = controller.status
            if !status.isEmpty && !status.hasPrefix("Downloading") { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeModel() -> DownloadableModel {
        DownloadableModel(
            id: "test-model",
            displayName: "Test model",
            kind: .stt,
            fileName: "ggml-test.bin",
            relativeDirectory: "whisper",
            remoteURL: URL(string: "https://example.invalid/ggml-test.bin")!)
    }

    /// The download lands in the right place, the controller reports it, and
    /// the owner is told to rescan.
    @MainActor
    func testDownloadInstallsTheModelAndNotifiesTheOwner() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-dltest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ModelPaths(root: root)

        let controller = ModelDownloadController(fetcher: FakeFetcher())
        let model = makeModel()

        var notifiedModel: DownloadableModel?
        let notified = expectation(description: "onInstalled was called")
        controller.onInstalled = {
            notifiedModel = model
            notified.fulfill()
        }

        controller.download(model, into: paths)
        await fulfillment(of: [notified], timeout: 5)

        XCTAssertNil(controller.lastError, "the download should not fail")
        XCTAssertEqual(controller.status, "Installed Test model.")
        let destination = model.destination(in: paths)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: destination.path),
            "the model should be on disk")
        XCTAssertTrue(controller.isInstalled(model, in: paths))
        XCTAssertEqual(notifiedModel?.id, "test-model")

        // The scanner must find it too - that is what the front page uses.
        let config = TTSConfigManager(
            persistURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vb-dltest-\(UUID().uuidString).json"))
        config.configureRoot(root)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: config.paths.whisperDir.appendingPathComponent("ggml-test.bin").path))
    }

    /// A failed download reports the error and installs nothing.
    @MainActor
    func testAFailedDownloadInstallsNothing() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-dlfail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ModelPaths(root: root)

        let controller = ModelDownloadController(fetcher: FakeFetcher(shouldFail: true))
        let model = makeModel()
        var notified = false
        controller.onInstalled = { notified = true }

        controller.download(model, into: paths)
        await waitForDownload(controller)

        XCTAssertNotNil(controller.lastError)
        XCTAssertFalse(notified, "a failed download must not trigger a rescan")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: model.destination(in: paths).path))
    }

    /// A Piper voice is only "installed" when its config sits next to it.
    ///
    /// The fake fetcher writes both files, so the companion rule - not the
    /// transport - is what this asserts. It deliberately uses a catalog-shaped
    /// voice *without* a checksum: a real entry would fail the integrity gate
    /// (the fake writes "fake model", not 63 MB of ONNX), which is covered by
    /// its own test below.
    @MainActor
    func testPiperVoiceNeedsItsConfig() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-dlvoice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ModelPaths(root: root)

        let controller = ModelDownloadController(fetcher: FakeFetcher())
        let voice = makeVoice()
        XCTAssertFalse(controller.isInstalled(voice, in: paths))

        // The model alone is not enough: the .onnx.json has to be there too.
        let destination = voice.destination(in: paths)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("fake model".utf8).write(to: destination)
        XCTAssertFalse(
            controller.isInstalled(voice, in: paths),
            "an .onnx without its .onnx.json is not a usable voice")

        controller.download(voice, into: paths)
        await waitForDownload(controller)

        XCTAssertNil(controller.lastError, "the download should not fail")
        XCTAssertTrue(controller.isInstalled(voice, in: paths))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.deletingLastPathComponent()
                    .appendingPathComponent("test-voice.onnx.json").path),
            "the companion file should be installed next to the model")
    }

    /// A checksum mismatch must delete the download instead of installing it.
    ///
    /// The downloader used to verify *and then keep* the file, so `isInstalled`
    /// reported a corrupted model as ready forever - the whole point of the
    /// checksum is to stop that.
    @MainActor
    func testAChecksumMismatchDiscardsTheDownload() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-dlsha-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ModelPaths(root: root)

        let controller = ModelDownloadController(fetcher: FakeFetcher())
        let bad = DownloadableModel(
            id: "test-bad-checksum",
            displayName: "Test model (bad checksum)",
            kind: .tts,
            fileName: "test-voice.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: URL(string: "https://example.invalid/test-voice.onnx")!,
            sha256: String(repeating: "0", count: 64))

        var notified = false
        controller.onInstalled = { notified = true }

        controller.download(bad, into: paths)
        await waitForDownload(controller)

        XCTAssertNotNil(controller.lastError, "a bad checksum must be reported")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bad.destination(in: paths).path),
            "a file that failed its checksum must not stay on disk")
        XCTAssertFalse(controller.isInstalled(bad, in: paths))
        XCTAssertFalse(notified, "a failed download must not report success")
    }

    /// A catalog-shaped Piper voice: model + `.onnx.json`, no checksum.
    private func makeVoice() -> DownloadableModel {
        DownloadableModel(
            id: "test-voice",
            displayName: "Test voice",
            kind: .tts,
            fileName: "test-voice.onnx",
            relativeDirectory: "piper/voice",
            remoteURL: URL(string: "https://example.invalid/test-voice.onnx")!,
            companions: [
                DownloadableModel.Companion(
                    fileName: "test-voice.onnx.json",
                    remoteURL: URL(string: "https://example.invalid/test-voice.onnx.json")!)
            ])
    }
}
