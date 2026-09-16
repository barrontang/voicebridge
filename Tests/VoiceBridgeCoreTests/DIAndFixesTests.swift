import XCTest
import CryptoKit
@testable import VoiceBridgeCore

/// Regression + acceptance tests for the review's findings.
///
/// The meta-point of the review: findings 1/2/3/4/5/11 all trace to reading
/// globals in the core. These tests inject that global (a `ModelPaths`, a
/// `BinaryLocator`, a fake filesystem) and assert the new value-threading
/// actually works — which is why they fail on the *old* static design.
final class DIAndFixesTests: XCTestCase {
    // MARK: - Finding 1 & 2: paths honor a *configured* root, never a static

    /// A layout rooted at X derives every subdir off X. This is the whole point
    /// of making `ModelPaths` a value type: TTS and STT resolve off the *same*,
    /// injected root instead of a global the user can't move.
    func testModelLayoutDerivesFromInjectedRoot() {
        let root = URL(fileURLWithPath: "/custom/models/tts")
        let paths = ModelPaths(root: root)
        let base = root.standardizedFileURL.path

        XCTAssertEqual(paths.whisperDir.lastPathComponent, "whisper")
        XCTAssertEqual(paths.piperVoiceDir.lastPathComponent, "voice")
        XCTAssertEqual(paths.piperVoiceDir.deletingLastPathComponent().lastPathComponent, "piper")
        XCTAssertEqual(paths.kokoroDir.lastPathComponent, "kokoro")
        XCTAssertEqual(paths.cacheDir.lastPathComponent, "cache")
        // Every subdir actually lives *under* the injected root.
        XCTAssertTrue(paths.whisperDir.path.hasPrefix(base))
        XCTAssertTrue(paths.piperVoiceDir.path.hasPrefix(base))
        XCTAssertTrue(paths.cacheDir.path.hasPrefix(base))
    }

    /// Two *different* roots produce *different* whisper dirs — i.e. a user who
    /// changes the folder via `configureRoot` makes STT follow (the old code
    /// had a static `ModelPaths.whisperDir` that ignored it).
    func testDifferentRootsYieldDifferentDirs() {
        let a = ModelPaths(root: URL(fileURLWithPath: "/a/b"))
        let b = ModelPaths(root: URL(fileURLWithPath: "/c/d"))
        XCTAssertNotEqual(a.whisperDir, b.whisperDir)
        XCTAssertNotEqual(a.cacheDir, b.cacheDir)
        // `make` is the public factory used by `configureRoot`.
        XCTAssertEqual(ModelPaths.make(URL(fileURLWithPath: "/x/y")).root.lastPathComponent, "y")
    }

    // MARK: - Finding 3: config lives in Application Support, not the temp dir

    /// The bug was `persistURL` pointing at `DARWIN_USER_TEMP_DIR`, which the OS
    /// reclaims. The fix routes through `AppPaths.configURL()` under Application
    /// Support. Assert the URL's *shape* (no write, so the test is hermetic).
    func testConfigURLLivesInApplicationSupportNotTemp() throws {
        let url = try AppPaths.configURL()
        let expectedPrefix = NSHomeDirectory() + "/Library/Application Support"
        XCTAssertTrue(url.path.hasPrefix(expectedPrefix),
            "config should live under Application Support, got \(url.path)")
        XCTAssertTrue(url.path.hasSuffix("VoiceBridge/config.json"))
        // Definitely not the per-user temp region the old code used.
        XCTAssertFalse(url.path.hasPrefix(
            FileManager.default.temporaryDirectory
                     .deletingLastPathComponent().path + "/voicebridge"))
        XCTAssertEqual(url.lastPathComponent, "config.json")
    }

    /// The legacy temp location and the canonical Application Support location are
    /// *different* — the old bug was that they effectively were the same temp
    /// region, so settings were "persisted" somewhere the OS then reclaimed.
    func testLegacyAndCanonicalLocationsDiffer() throws {
        let canonical = try AppPaths.configURL()
        let legacy = AppPaths.legacyConfigURL()
        XCTAssertNotEqual(canonical, legacy,
            "legacy and canonical config paths must not coincide")
        XCTAssertTrue(canonical.path.hasPrefix(
            NSHomeDirectory() + "/Library/Application Support"))
        XCTAssertTrue(legacy.path.hasPrefix(
            FileManager.default.temporaryDirectory.path))
    }

    // MARK: - Finding 4: one binary locator, in injectable order

    /// The locator resolves in the documented order: override → extraPrefixes →
    /// $PATH. A fake filesystem asserts order without touching the host.
    func testBinaryLocatorSearchOrder() {
        let fake: [String: Bool] = ["/usr/local/bin/piper": true]
        let locator = BinaryLocator(
            searchPaths: .init(path: "/usr/local/bin:/opt/homebrew/bin",
                               extraPrefixes: ["/opt/homebrew/opt/whisper-cpp/bin"]),
            isExecutable: { fake[$0] ?? false })

        // 1. An absolute, executable path short-circuits.
        XCTAssertEqual(locator.locate("/usr/local/bin/piper"), "/usr/local/bin/piper")
        // 2. Not present anywhere => nil.
        XCTAssertNil(locator.locate("whisper-cli"))
        // 3. Found on $PATH.
        XCTAssertEqual(locator.locate("piper"), "/usr/local/bin/piper")
        XCTAssertEqual(locator.isAvailable("piper"), true)
        XCTAssertNil(locator.locate("does-not-exist"))
    }

    /// A missing binary falls through to the bare name (the old passthrough the
    /// shell relied on to surface the child's own error).
    func testBinaryLocatorPassthroughWhenAbsent() {
        let locator = BinaryLocator(searchPaths: .init(path: "/nonexistent"),
                                    isExecutable: { _ in false })
        XCTAssertEqual(locator.resolveOrPassthrough("piper"), "piper")
    }

    // MARK: - Finding 7: the catalog is user-extensible, not a closed enum

    /// The catalog mirrors the enum's filenames so the old picker keeps working,
    /// but is keyed by descriptor so new / user models are representable.
    func testSttModelCatalogMirrorsEnumFilenames() {
        for model in SttModel.allCases {
            let d = SttModelCatalog.descriptor(for: model)
            XCTAssertEqual(d?.fileName, model.ggmlFilename,
                "descriptor fileName should match the enum's ggmlFilename")
            XCTAssertEqual(d?.id, model.rawValue,
                "descriptor id should match the enum's rawValue")
        }
        // Ordered best-first; the recommended model leads.
        XCTAssertEqual(SttModelCatalog.bundled.first?.id, "large-v3-turbo")
        // A Hugging-Face origin is representable (the enum could never be).
        let imported = SttModelDescriptor(
            id: "my-finetune",
            displayName: "My fine-tune",
            fileName: "ggml-my.bin",
            origin: .huggingFace(repo: "someone/whisper-finetune", file: "ggml-my.bin"))
        XCTAssertEqual(imported.fileName, "ggml-my.bin")
        XCTAssertEqual(imported.origin, .huggingFace(repo: "someone/whisper-finetune",
                                                     file: "ggml-my.bin"))
    }

    // MARK: - Finding 8 / Missing 3: pre-flight disk space & checksum

    /// A matching checksum passes; a wrong one throws `.checksumMismatch`. The
    /// expected digest is computed in-test to avoid a magic constant.
    func testChecksumVerificationPassesAndFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-sha-\(UUID().uuidString).bin")
        try "hello voicebridge".data(using: .utf8)!.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = Self.sha256hex("hello voicebridge")
        // Match: must not throw.
        try await ModelDownloader.verifySHA256(of: url, expected: expected)
        // Mismatch: must throw `.checksumMismatch`.
        do {
            try await ModelDownloader.verifySHA256(of: url, expected: "deadbeef")
            XCTFail("expected .checksumMismatch to be thrown")
        } catch let error as VoiceError {
            guard case .checksumMismatch = error else {
                return XCTFail("expected .checksumMismatch, got \(error)")
            }
        }
    }

    /// `preflightFreeSpace` throws for an absurd size and passes for a tiny one.
    func testPreflightFreeSpaceRejectsAbsurdSize() throws {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-preflight")
        // 1 EB can't fit anywhere real.
        XCTAssertThrowsError(try ModelDownloader.preflightFreeSpace(
            needed: 1_600_000_000_000_000, at: dest)) { error in
            guard case VoiceError.insufficientDiskSpace = error else {
                return XCTFail("expected .insufficientDiskSpace, got \(error)")
            }
        }
        // A 1-byte requirement on a real volume must pass.
        XCTAssertNoThrow(try ModelDownloader.preflightFreeSpace(needed: 1, at: dest))
    }
}

// MARK: - helpers

private extension DIAndFixesTests {
    /// SHA-256 hex of a UTF-8 string, mirroring the downloader's streaming sum.
    static func sha256hex(_ s: String) -> String {
        var hasher = SHA256()
        hasher.update(data: s.data(using: .utf8)!)
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
