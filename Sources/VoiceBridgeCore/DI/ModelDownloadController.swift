import Foundation
import Combine

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
    private var currentTask: Task<Void, Never>?

    public init() {}

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
                try await self.fetch(model.remoteURL, to: destination)
                for companion in companions {
                    try await self.fetch(companion.url, to: companion.destination)
                }
                if let expected = model.sha256 {
                    try await ModelDownloader.verifySHA256(of: destination, expected: expected)
                }
                self.status = "Installed \(model.displayName)."
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

    /// Stream one file into place.
    private func fetch(_ remote: URL, to destination: URL) async throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Preflight: refuse a download the disk cannot hold.
        if let size = await remoteContentLength(remote) {
            _ = try ModelDownloader.preflightFreeSpace(needed: size, at: destination)
        }

        for try await progress in await downloader.download(remote, to: destination) {
            if Task.isCancelled { throw CancellationError() }
            if let active = activeModelID {
                self.progress[active] = progress.fractionComplete
            }
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
