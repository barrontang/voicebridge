import XCTest
@testable import VoiceBridgeCore

/// P1 of the review: edge-tts sends text off-device to a Microsoft gateway, and
/// that privacy fact used to live only in a doc comment. `requiresNetwork` is the
/// typed signal the orchestrator reads to warn the user *at the point of use*.
/// These tests pin the contract so a new offline engine can't silently inherit
/// the wrong value, and edge-tts can't lose its override.
final class TTSBackendTests: XCTestCase {

        /// edge-tts is the one network-bound engine.
    func testEdgeTTSCanBeReachOverTheNetwork() {
                 // `EdgeTTSBackend` overrides `requiresNetwork` to `true`.
        let edge = EdgeTTSBackend()
        XCTAssertTrue(edge.requiresNetwork,
         "edge-tts transits Microsoft servers — the flag must warn the user")
                // Default extension is `false`, so an offline backend doesn't warn.
        XCTAssertFalse(SystemVoiceBackend().requiresNetwork)
         }

        /// The built-in / offline engine must never claim network egress.
    func testSystemVoiceIsOffline() {
        XCTAssertFalse(SystemVoiceBackend().requiresNetwork,
         "AVSpeech speaks entirely on-device — no network warning")
         }

        /// The default extension yields `false`, so a brand-new engine is
         /// assumed offline until it explicitly overrides.
    func testUnimplementedEnginesDefaultToOffline() {
        let k = KokoroBackend()
        XCTAssertFalse(k.requiresNetwork,
         "Kokoro runs in-process; it must not warn about network egress")
         }
}
