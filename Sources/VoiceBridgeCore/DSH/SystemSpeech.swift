import Foundation

/// Speak text with macOS `say`.
///
/// Used for DSH answers: offline, available on every Mac, works from a
/// headless process (the in-place AVSpeech engine needs an app run loop to
/// report completion), and it picks a Chinese voice for Chinese text.
public enum SystemSpeech {

    static let say = "/usr/bin/say"
    static let chineseVoices = ["Tingting", "Lanlan", "Meijia", "Han", "Sinji"]

    /// Probing a voice means running `say -o` and waiting for it, so the answer
    /// is remembered for the life of the process: a chat reads many answers.
    private static let chineseVoice = VoiceProbe()

    /// Speak `text` and return when it has finished.
    public static func speak(_ text: String, voice: String? = nil) async throws {
        var args: [String] = []
        if let voice {
            args = ["-v", voice]
        } else if WordDiff.isMostlyCJK(text), let zh = await resolvedChineseVoice() {
            args = ["-v", zh]
        }
        _ = try await Shell.run(at: say, arguments: args + [text], timeout: 600)
    }

    /// The installed Chinese voice, probed at most once (`nil` = none of them).
    static func resolvedChineseVoice() async -> String? {
        await chineseVoice.resolve { await firstInstalledVoice(chineseVoices) }
    }

    /// The first installed `say` voice (a missing one exits non-zero).
    static func firstInstalledVoice(_ candidates: [String]) async -> String? {
        let probe = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-say-probe-\(UUID().uuidString).aiff").path
        defer { try? FileManager.default.removeItem(atPath: probe) }
        for name in candidates {
            if (try? await Shell.run(at: say, arguments: ["-v", name, "-o", probe, "好"])) != nil {
                return name
            }
        }
        return nil
    }
}

/// Caches the one-off "which Chinese voice exists?" probe.
private actor VoiceProbe {
    /// `nil` = not probed yet; `.some(nil)` = probed, and none was found.
    private var resolved: String??

    func resolve(_ probe: @Sendable () async -> String?) async -> String? {
        if let resolved { return resolved }
        let found = await probe()
        resolved = .some(found)
        return found
    }
}
