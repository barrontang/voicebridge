import Foundation

/// Speak text with macOS `say`.
///
/// Used for DSH answers: offline, available on every Mac, works from a
/// headless process (the in-place AVSpeech engine needs an app run loop to
/// report completion), and it picks a Chinese voice for Chinese text.
public enum SystemSpeech {

    static let say = "/usr/bin/say"
    static let chineseVoices = ["Tingting", "Lanlan", "Meijia", "Han", "Sinji"]

    /// Speak `text` and return when it has finished.
    public static func speak(_ text: String, voice: String? = nil) async throws {
        var args: [String] = []
        if let voice {
            args = ["-v", voice]
        } else if WordDiff.isMostlyCJK(text), let zh = await firstInstalledVoice(chineseVoices) {
            args = ["-v", zh]
        }
        _ = try await Shell.run(at: say, arguments: args + [text], timeout: 600)
    }

    /// The first installed `say` voice (a missing one exits non-zero).
    static func firstInstalledVoice(_ candidates: [String]) async -> String? {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-say-probe.aiff").path
        for name in candidates {
            if (try? await Shell.run(at: say, arguments: ["-v", name, "-o", probe, "好"])) != nil {
                return name
            }
        }
        return nil
    }
}
