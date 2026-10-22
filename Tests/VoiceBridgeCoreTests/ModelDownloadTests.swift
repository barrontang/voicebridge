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

        func fetch(_ remote: URL,
                   to destination: URL,
                   progress: @escaping @Sendable (Double) -> Void) async throws {
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
    private func waitForDownload(_ controller: ModelDownloadController,
                                 timeout: TimeInterval = 5) async {
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path),
                      "the model should be on disk")
        XCTAssertTrue(controller.isInstalled(model, in: paths))
        XCTAssertEqual(notifiedModel?.id, "test-model")

        // The scanner must find it too - that is what the front page uses.
        let config = TTSConfigManager(persistURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-dltest-\(UUID().uuidString).json"))
        config.configureRoot(root)
        XCTAssertTrue(FileManager.default.fileExists(
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
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: model.destination(in: paths).path))
    }

    /// A Piper voice is only "installed" when its config sits next to it.
    @MainActor
    func testPiperVoiceNeedsItsConfig() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-dlvoice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ModelPaths(root: root)

        let controller = ModelDownloadController(fetcher: FakeFetcher())
        let voice = ModelCatalog.tts[0]
        XCTAssertFalse(controller.isInstalled(voice, in: paths))

        controller.download(voice, into: paths)
        await waitForDownload(controller)

        // The fake fetcher wrote both the model and its config, so it counts
        // as installed.
        XCTAssertTrue(controller.isInstalled(voice, in: paths))
    }
}
