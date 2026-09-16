import Foundation

/// Bounds the TTS scratch/cache directory so it can't grow without limit.
///
/// `TTSManager.speak` writes a new UUID-named WAV per synthesis, and nothing was
/// ever deleting those (P1 of the review). Under heavy use — a voice agent that
/// speaks hundreds of lines a day, or a "read this 30-page PDF aloud" session —
/// the cache would balloon for the life of the app with no reaping. This type
/// owns the one policy that trims it back, and the test injects a fake clock so
/// the aging math is deterministic.
///
/// It's a `Sendable` value type of pure-ish functions over paths, so a
/// `TTSManager` on the main actor can call it, and a test can call it against a
/// temp dir with no real clock involved.
public struct CacheGuardian: Sendable {

        /// How aggressively to trim.
    public struct Limits: Sendable, Equatable {
              /// Hard cap on the number of files kept (`Int.max` disables the cap).
        public var maxFiles: Int
              /// Hard cap on total bytes kept.
        public var maxBytes: Int64
              /// A file modified more than this long ago is deleted outright;
              /// `0` disables age-based cleanup. 30 days is the default —
              /// synthesis output is cheap to regenerate and rarely revisited.
        public var maxAge: TimeInterval

        public init(maxFiles: Int = 1_000,
                    maxBytes: Int64 = 2 << 30,            // 2 GiB
                    maxAge: TimeInterval = 30 * 86_400) { // 30 days
            self.maxFiles = maxFiles
            self.maxBytes = maxBytes
            self.maxAge = maxAge
          }

             /// Keep essentially everything — large caps, no age cutoff.
        public static let unbounded = Limits(maxFiles: .max,
                                             maxBytes: Int64.max,
                                             maxAge: 0)
      }

        /// What a prune pass did.
    public struct Outcome: Sendable, Equatable {
        public let removedCount: Int
        public let removedBytes: Int64

        public var isEmpty: Bool { removedCount == 0 }

        public init(removedCount: Int, removedBytes: Int64) {
            self.removedCount = removedCount
            self.removedBytes = removedBytes
          }
      }

       /// Trim `directory` to within `limits`, deleting oldest-first.
       ///
       /// `now` is injectable so the aging decision is deterministic in tests;
       /// pass `Date()` to run against the real clock. Only *regular files* in
       /// the top level are ever touched — sub-directories are ignored, and a
       /// missing directory is a no-op.
       @discardableResult
    public func prune(directory: URL,
                      limits: Limits = .init(),
                      now: Date = Date()) -> Outcome {
        let fm = FileManager.default

            // No directory, or we can't list it → nothing to reap.
        var isDir = ObjCBool(false)
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(
                   at: directory,
                   includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                   options: [.skipsSubdirectoryDescendants]) else {
            return .init(removedCount: 0, removedBytes: 0)
          }

        struct Entry { let url: URL; let size: Int64; let mtime: Date }

            // Resolve metadata; skip anything we can't stat (e.g. a dangling symlink).
        var entries2: [Entry] = []
        for url in entries {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value,
                   let mtime = attrs[.modificationDate] as? Date else { continue }
            entries2.append(Entry(url: url, size: size, mtime: mtime))
          }

            // Newest first: the first `maxFiles` and the byte-budget's worth are
             // kept (the freshest, most likely to be read next); the coldest are evicted.
        entries2.sort { $0.mtime > $1.mtime }

        var keptCount = 0
        var keptBytes: Int64 = 0
        var removedCount = 0
        var removedBytes: Int64 = 0

        for e in entries2 {
             // A file is evicted if it's past its age, or if keeping it would
            // exceed a count/byte budget once the already-kept set is accounted
            // for.
            let tooOld   = limits.maxAge > 0 && now.timeIntervalSince(e.mtime) > limits.maxAge
            let overCount = keptCount >= limits.maxFiles
            let overBytes = keptBytes + e.size > limits.maxBytes

            if !tooOld && !overCount && !overBytes {
                  // Keep.
                keptCount += 1
                keptBytes += e.size
                 continue
                }

            // Evict.
            try? fm.removeItem(at: e.url)
            removedCount += 1
            removedBytes += e.size
           }

        return .init(removedCount: removedCount, removedBytes: removedBytes)
       }
}
