import XCTest
@testable import VoiceBridgeCore

/// P1 of the review: the TTS cache dir was unbounded. `CacheGuardian.prune` is
/// the one policy that trims it back. These tests drive it against a temp dir
/// with a fully injected clock (`now`), so the timing math is deterministic and
/// never depends on wall-clock.
final class CacheGuardianTests: XCTestCase {

      /// A helper cache dir that `removeItem` after the test.

    private func makeCache(_ body: (URL, Date) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
                  .appendingPathComponent("vb-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_700_000_000) // fixed reference clock
        try body(dir, now)
       }

      /// Add a tiny file with a controlled size and a controlled modification
      /// time relative to `now` (`ageSeconds` in the past).
    private static func touch(_ dir: URL, name: String,
                              size: Int, ageSeconds: TimeInterval, now: Date) throws {
        let url = dir.appendingPathComponent(name)
        let data = Data([UInt8](repeating: 0x61, count: max(1, size)))   // deterministic content
        try data.write(to: url)
        let mtime = now.addingTimeInterval(-ageSeconds)
        try FileManager.default.setAttributes(
              [.modificationDate: mtime],
              ofItemAtPath: url.path)
        }

       // MARK: - Count cap

              /// With a 3-file cap and 5 files present, the two *oldest* files are
             /// removed and the three newest survive.
    func testPruneEnforcesMaxFilesFromColdEnd() throws {
        try makeCache { dir, now in
            for i in 0..<5 {
                  // file0 newest, file4 coldest.
                try CacheGuardianTests.touch(dir, name: "f\(i).wav",
                                             size: 100, ageSeconds: Double(i) * 3_600, now: now)
               }
                let outcome = CacheGuardian().prune(directory: dir,
                         limits: .init(maxFiles: 3, maxBytes: .max, maxAge: 0), now: now)

         // Two evicted, oldest first.
            XCTAssertEqual(outcome.removedCount, 2)
            XCTAssertEqual(outcome.removedBytes, 200)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertTrue(["f0.wav", "f1.wav", "f2.wav"].allSatisfy { remaining.contains($0) })
            XCTAssertFalse(remaining.contains("f3.wav"))
            XCTAssertFalse(remaining.contains("f4.wav"))
            }
        }

       // MARK: - Byte cap

              /// A byte budget trims the coldest files until the total fits, and the
             /// newest (small + most recently used) files are kept.
    func testPruneEnforcesMaxBytes() throws {
        try makeCache { dir, now in
            try CacheGuardianTests.touch(dir, name: "big.wav",  size: 1_000, ageSeconds: 7_200, now: now)
            try CacheGuardianTests.touch(dir, name: "mid.wav",  size: 500,   ageSeconds: 3_600, now: now)
            try CacheGuardianTests.touch(dir, name: "fresh.wav", size: 100,   ageSeconds: 60,   now: now)

                 // Keep <=700 bytes: evict the coldest 1000-B file, keep mid+fresh = 600.
            let outcome = CacheGuardian().prune(directory: dir,
                     limits: .init(maxFiles: .max, maxBytes: 700, maxAge: 0), now: now)

            XCTAssertEqual(outcome.removedCount, 1)
            XCTAssertEqual(outcome.removedBytes, 1_000)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertFalse(remaining.contains("big.wav"))
            XCTAssertTrue(remaining.contains("mid.wav"))
            XCTAssertTrue(remaining.contains("fresh.wav"))
            }
        }

       // MARK: - Age gate

              /// A file older than `maxAge` is evicted even when count/byte budgets
             /// have headroom.
    func testPruneEvictsByAge() throws {
        try makeCache { dir, now in
            try CacheGuardianTests.touch(dir, name: "old.wav",  size: 10, ageSeconds: 100_000, now: now)
            try CacheGuardianTests.touch(dir, name: "new.wav",  size: 10, ageSeconds: 5,     now: now)

                 // 100-second cutoff: only `old` (100 000 s old) is evicted.
            let outcome = CacheGuardian().prune(directory: dir,
                     limits: .init(maxFiles: .max, maxBytes: .max, maxAge: 100), now: now)

            XCTAssertEqual(outcome.removedCount, 1)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertTrue(remaining.count == 1)
            XCTAssertFalse(remaining.contains("old.wav"))
            }
        }

       // MARK: - No-op cases

              /// A dir already within all limits prunes nothing.
    func testPruneLeavesCompliantCacheAlone() throws {
        try makeCache { dir, now in
            try CacheGuardianTests.touch(dir, name: "keep.wav", size: 10, ageSeconds: 5, now: now)
             let outcome = CacheGuardian().prune(directory: dir,
                     limits: .init(maxFiles: 5, maxBytes: 1_000, maxAge: 100), now: now)
            XCTAssertTrue(outcome.isEmpty)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertEqual(remaining.count, 1)
            }
        }

              /// A missing directory is a harmless no-op, not a crash.
    func testPruneMissingDirectoryIsNoop() throws {
        let dir = FileManager.default.temporaryDirectory
                  .appendingPathComponent("vb-cache-absent-\(UUID().uuidString)")
        let outcome = CacheGuardian().prune(directory: dir,
                 limits: .init(maxFiles: 3, maxBytes: 100, maxAge: 100),
                now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(outcome.isEmpty)
        }
}
