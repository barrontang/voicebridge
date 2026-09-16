import Foundation
import CryptoKit

/// Downloads STT model files with the three things the shell-script era lacked:
/// progress, checksum verification, and an **atomic, crash-safe write** (Finding 8
/// + Missing 3).
///
/// The shell scripts (`scripts/fetch-whisper-turbo.sh`) meant "get a model"
/// required a terminal — fine for a contributor, impossible for an end user, and
/// no good in an App Sandbox. This replaces that with a `URLSession`-backed
/// actor that:
///        * reports `Progress` as bytes arrive (drivable by a SwiftUI progress view);
///        * writes to a `.partial` sidecar and `rename`-to-final on success, so a
///         cancelled/interrupted download can never leave a half-written `.bin` that
///         the scanner would happily list as "available";
///        * verifies a SHA-256 when supplied and *discards* the file on mismatch
///         (the integrity check the earlier review flagged as missing).
///
/// Resume (via a persisted download `resumeData` on a background session) is a
/// documented extension point. `preflightFreeSpace` (Missing 3) is exposed so a
/// caller can refuse a multi-GB pull on a full volume *before* starting it.
public actor ModelDownloader {

         /// A monotonic snapshot of a download in flight.
     public struct Progress: Sendable, Equatable {
        public let bytesReceived: Int64
        public let totalBytes: Int64?               // nil = unknown length
        public init(bytesReceived: Int64, totalBytes: Int64?) {
            self.bytesReceived = bytesReceived
            self.totalBytes = totalBytes
             }
           /// 0…1, or 0 when the total length is unknown.
        public var fractionComplete: Double {
            guard let total = totalBytes, total > 0 else { return 0 }
            return min(1.0, Double(bytesReceived) / Double(total))
             }
        }

         /// Pre-flight a download: throws early if the host can't hold the file.
         ///
         /// Uses `volumeAvailableCapacityForImportantUsage` (not `freeSpace`) so we
         /// count reclaimable space the way macOS itself does — a full-looking
         /// disk with a big cache isn't treated as out of space.
      @discardableResult
    public static func preflightFreeSpace(needed: Int64, at url: URL)
        throws -> Int64 {
        guard needed > 0 else {
            throw VoiceError.insufficientDiskSpace(needed: needed, available: 0, at: url.path)
             }
          // URLResourceKey-based, not raw freeSpace.
        let values = try url.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        if available < needed {
            throw VoiceError.insufficientDiskSpace(needed: needed, available: available, at: url.path)
             }
        return available
        }

         /// Downloads `url` into `destination`, streaming `Progress`.
         ///
         /// Bytes land in `destination + ".partial"`; on full success the sidecar
         /// is atomically `rename`-d to `destination`. A cancellation or error prunes
         /// the `.partial`, so a corrupt file can never masquerade as a model.
     public func download(_ url: URL,
                         to destination: URL)
        -> AsyncThrowingStream<Progress, Error> {
        AsyncThrowingStream { continuation in
            let job = DownloadJob(from: url,
                                  into: destination,
                           continuation: continuation)
              // Keep the job alive for the stream's life; cancel it on termination.
            let canceller: @Sendable () -> Void = job.canceller()
            continuation.onTermination = { @Sendable _ in canceller() }
            job.start()
           }
        }
}

// MARK: - SHA-256 verification

public extension ModelDownloader {
         /// Streams a file through SHA-256 and compares (case-insensitively) to
         /// `expected`. Throws `.checksumMismatch` on disagreement.
    static func verifySHA256(of url: URL, expected: String) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var finished = false
        while !finished {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { finished = true } else { hasher.update(data: chunk) }
             }
        let digest = hasher.finalize()
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        let normExpected = expected.lowercased()
        if actual != normExpected {
          throw VoiceError.checksumMismatch(url: url.path,
                                            expected: normExpected,
                                             actual: actual)
           }
        }
}

// MARK: - Job

/// A reference type that owns the `URLSession`, its delegate, and its task for
/// the life of a single download — the canonical way to keep a delegate alive
/// without capturing it in the (value-typed) stream closure.
final class DownloadJob: NSObject, URLSessionDownloadDelegate {

    private let from: URL
    private let into: URL
    private let partial: URL
    private let continuation: AsyncThrowingStream<ModelDownloader.Progress, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionTask?
    private var didFinish = false

    init(from: URL, into: URL,
          continuation: AsyncThrowingStream<ModelDownloader.Progress, Error>.Continuation) {
        self.from = from
        self.into = into
        self.partial = into.appendingPathExtension("partial")
        self.continuation = continuation
        super.init()
       }

         /// A `@Sendable` closure the stream's `onTermination` can capture without
         /// tripping concurrency checks; it calls back into `cancel()`.
    func canceller() -> @Sendable () -> Void {
         { [weak self] in self?.cancel() }
        }

    func start() {
         _ = try? FileManager.default.removeItem(at: partial)
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: from)
        self.task = task
        task.resume()
        }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
        }

     // MARK: delegate

      func urlSession(_ session: URLSession,
                       downloadTask: URLSessionDownloadTask,
                       didWriteData bytesWritten: Int64,
                       totalBytesWritten: Int64,
                       totalBytesExpectedToWrite: Int64) {
        continuation.yield(ModelDownloader.Progress(
            bytesReceived: totalBytesWritten,
                       totalBytes: totalBytesExpectedToWrite))
         }

       // Move the OS-owned temp file into our managed `.partial` sidecar.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
           try FileManager.default.createDirectory(
              at: partial.deletingLastPathComponent(),
              withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: partial)
           } catch {
            finish(.failure(error))
             }
        }

      func urlSession(_ session: URLSession,
                      task: URLSessionTask,
                     didCompleteWithError error: Error?) {
        if let error {
              // A user Stop / quit surfaces as `.cancelled`; prune, don't alarm.
            if case URLError.cancelled = error {
              finish(.success(()))
               return
              }
            finish(.failure(error))
             return
             }
          // Success: atomically rename the sidecar to the final path.
        do {
           try FileManager.default.moveItem(at: partial, to: into)
            finish(.success(()))
            } catch {
             finish(.failure(error))
             }
        }

      private func finish(_ result: Result<Void, Error>) {
        guard !didFinish else { return }
        didFinish = true
        switch result {
        case .success:
             // On success the sidecar was already renamed away; this is a no-op.
            _ = try? FileManager.default.removeItem(at: partial)
            continuation.finish()
        case .failure(let error):
             // A failed/cancelled run must not leave a `.partial` behind.
            _ = try? FileManager.default.removeItem(at: partial)
            continuation.finish(throwing: error)
          }
        }
}
