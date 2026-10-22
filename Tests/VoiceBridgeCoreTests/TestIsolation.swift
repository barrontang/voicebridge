import XCTest
import Foundation
@testable import VoiceBridgeCore

/// The settings file can be redirected with `VOICEBRIDGE_CONFIG_PATH`.
///
/// Why this matters: a test that constructs a config manager *without* an
/// explicit settings file would write into the user's real
/// `~/Library/Application Support/VoiceBridge/config.json` (a throwaway
/// model root once ended up there). The CI workflow sets the variable, and
/// the CI lint greps the tests for a manager that is built without an
/// explicit path.
final class SettingsIsolationTests: XCTestCase {

    func testTheEnvironmentCanRedirectTheSettingsFile() throws {
        let previous = ProcessInfo.processInfo.environment["VOICEBRIDGE_CONFIG_PATH"]
        defer {
            if let previous {
                setenv("VOICEBRIDGE_CONFIG_PATH", previous, 1)
            } else {
                unsetenv("VOICEBRIDGE_CONFIG_PATH")
            }
        }

        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-redirect-\(UUID().uuidString).json")
        setenv("VOICEBRIDGE_CONFIG_PATH", target.path, 1)

        XCTAssertEqual(try AppPaths.configURL().path, target.path)
    }

    /// A manager built with an explicit settings file must write *there* and
    /// nowhere else.
    @MainActor
    func testAnExplicitSettingsFileIsUsed() throws {
        let target = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-explicit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: target) }

        let config = TTSConfigManager(persistURL: target)
        config.selectedMode = .kokoro
        XCTAssertNotNil(config.persist())

        let data = try Data(contentsOf: target)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["mode"] as? String, "Kokoro-82M (local)")
    }
}
