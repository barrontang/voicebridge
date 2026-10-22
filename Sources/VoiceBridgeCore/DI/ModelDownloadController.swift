import Foundation
import Combine

/// Fetches one remote file into a local path.
///
/// The controller talks to this instead of `URLSession` directly, so the
/// install / verify / notify flow can be tested without a network (and so a
/// different transport could be plugged in).
public protocol ModelFetcher: Sendable {
    /// Download `remote` into `destination`, reporting progress (0…1).
    ///
    /// The file must be complete and in place when the call returns; an
    /// implementation that fails must leave nothing behind that could pass
    /// for an installed model.
    func fetch(_ remote: URL,
               to destination: URL,
               progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The production fetcher: a streaming download with a disk-space preflight.
public struct URLSessionModelFetcher: ModelFetcher {

    private let downloader = ModelDownloader()

    public init() {}

    public func fetch(_ remote: URL,
                      to destination: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Refuse a download the disk cannot hold (before we start).
        if let size = await remoteContentLength(remote) {
            _ = try ModelDownloader.preflightFreeSpace(needed: size, at: destination)
        }

        for try await update in await downloader.download(remote, to: destination) {
            progress(update.fractionComplete)
            }
    }

    /// The size of a remote file, when the server tells us.
    private func remoteContentLength(_ url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let head = response as? HTTPURLResponse else { return nil }
        let length = head.expectedContentLength
        return length > 0 ? length : nil
    }
}

/// Drives `ModelDownloader` for the Settings page: progress, cancellation and
/// the "is it already on disk?" check.
@MainActor
public final class ModelDownloadController: ObservableObject {

    /// What the UI needs to draw a row.
    public struct Row: Identifiable, Sendable {
        public let model: DownloadableModel
        public let isInstalled: Bool
        public var id: String { model.id }
    }

    /// Per-model progress, 0…1 (nil when the total size is unknown).
    @Published public private(set) var progress: [String: Double] = [:]
    /// The model currently downloading (nil = idle).
    @Published public private(set) var activeModelID: String?
    /// A short, human-readable status line.
    @Published public private(set) var status = ""
    /// The last error, if any.
    @Published public private(set) var lastError: String?

    private let downloader = ModelDownloader()
    private let fetcher: any ModelFetcher
    private var currentTask: Task<Void, Never>?

    /// Called after a model was installed (and verified).
    ///
    /// The owner uses it to rescan: without it the freshly downloaded model
    /// stays invisible - the front page keeps saying "no whisper models on
    /// disk" until the app is restarted.
    public var onInstalled: (() -> Void)?

    public init(fetcher: any ModelFetcher = URLSessionModelFetcher()) {
        self.fetcher = fetcher
    }

    /// Is `model` already installed under `root`?
    public func isInstalled(_ model: DownloadableModel, in root: ModelPaths) -> Bool {
        let fm = FileManager.default
        let destination = model.destination(in: root)
        guard fm.fileExists(atPath: destination.path) else { return false }
        // A Piper voice is only usable with its config next to it.
        for companion in model.companions {
            let sidecar = destination.deletingLastPathComponent()
                .appendingPathComponent(companion.fileName)
            guard fm.fileExists(atPath: sidecar.path) else { return false }
        }
        return true
    }

    /// The rows for a catalog section.
    public func rows(for models: [DownloadableModel], in root: ModelPaths) -> [Row] {
        models.map { Row(model: $0, isInstalled: isInstalled($0, in: root)) }
    }

    /// Download `model` (and its companions) into `root`.
    ///
    /// The file is streamed into a `.partial` sidecar and renamed on success,
    /// so an interrupted download can never masquerade as an installed model.
    public func download(_ model: DownloadableModel, into root: ModelPaths) {
        guard currentTask == nil else {
            status = "A download is already running."
            return
        }
        let destination = model.destination(in: root)
        let companions = model.companions.map {
            (url: $0.remoteURL,
             destination: destination.deletingLastPathComponent().appendingPathComponent($0.fileName))
        }
        let fetcher = self.fetcher

        currentTask = Task { [weak self] in
            guard let self else { return }
            self.activeModelID = model.id
            self.status = "Downloading \(model.displayName)…"
            self.lastError = nil
            defer {
                self.activeModelID = nil
                self.progress[model.id] = nil
                self.currentTask = nil
            }
            do {
                try await fetcher.fetch(model.remoteURL, to: destination) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, let active = self.activeModelID else { return }
                        self.progress[active] = fraction
                        }
                    }
                for companion in companions {
                    try await fetcher.fetch(companion.url, to: companion.destination) { _ in }
                }
                if let expected = model.sha256 {
                    try await ModelDownloader.verifySHA256(of: destination, expected: expected)
                }
                self.status = "Installed \(model.displayName)."
                // The model is on disk now - let the app rescan.
                self.onInstalled?()
            } catch is CancellationError {
                self.status = "Download cancelled."
            } catch {
                self.lastError = error.localizedDescription
                self.status = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    /// Cancel the running download.
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        activeModelID = nil
        status = "Download cancelled."
    }
}
