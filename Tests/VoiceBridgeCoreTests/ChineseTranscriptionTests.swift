import Foundation
import XCTest

@testable import VoiceBridgeCore

/// Regression: the transcript must be in the *spoken* language, never a
/// pseudo-translation into English.
///
/// `whisper-cli` defaults its language to **English** when `-l` is omitted, so
/// the old code (which passed `-l` only for a pinned language) transcribed
/// Chinese as if it were English — "Today's weather is good. Let's go to the
/// 公園". `WhisperCliBackend` now passes `-l auto` for an unpinned language, and
/// never `-tr` (translate).
final class ChineseTranscriptionTests: XCTestCase {

    // MARK: - Deterministic (no model, no audio)

    /// An unpinned language becomes `-l auto`, not an implicit English default.
    func testUnpinnedLanguageBecomesAuto() {
        let args = WhisperCliBackend.baseArguments(
            modelPath: "/m.bin", audioPath: "/a.wav", language: nil, useTimestamps: false)
        XCTAssertEqual(languageFlag(in: args), "auto")
    }

    /// A pinned language is passed through verbatim.
    func testPinnedLanguageIsHonoured() {
        let args = WhisperCliBackend.baseArguments(
            modelPath: "/m.bin", audioPath: "/a.wav", language: "zh", useTimestamps: true)
        XCTAssertEqual(languageFlag(in: args), "zh")
    }

    /// The backend must never ask whisper to translate — the output language
    /// always matches the speech.
    func testNeverTranslates() {
        for language in [nil, "zh", "en", "ja"] {
            let args = WhisperCliBackend.baseArguments(
                modelPath: "/m.bin", audioPath: "/a.wav", language: language, useTimestamps: false)
            XCTAssertFalse(args.contains("-tr"), "translate flag leaked for \(language ?? "auto")")
            XCTAssertFalse(args.contains("--translate"))
            XCTAssertTrue(args.contains("-l"), "a language flag must always be passed")
        }
    }

    private func languageFlag(in args: [String]) -> String? {
        guard let i = args.firstIndex(of: "-l"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - End-to-end (opt-in: needs whisper-cli, a model, and a Chinese voice)

    func testUnpinnedChineseSpeechTranscribesToChinese() async throws {
        guard ProcessInfo.processInfo.environment["VOICEBRIDGE_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("set VOICEBRIDGE_NETWORK_TESTS=1 to run the whisper integration test")
        }
        let whisperDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voicebridge/models/tts/whisper")
        let model = SttModel.largeV3Turbo
        guard
            FileManager.default.fileExists(
                atPath: whisperDir.appendingPathComponent(model.ggmlFilename).path)
        else { throw XCTSkip("the whisper model is not installed") }

        let wav = try makeChineseWAV()
        defer { try? FileManager.default.removeItem(at: wav) }

        let backend = WhisperCliBackend(modelDirectory: whisperDir)
        let result = try await backend.transcribe(
            audio: wav, language: nil, model: model, useTimestamps: false)

        let hasCJK = result.text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        XCTAssertTrue(
            hasCJK,
            "Chinese speech must transcribe to Chinese, not English. Got: \(result.text)")
    }

    /// Synthesize a short Chinese clip at whisper's shape (16 kHz mono WAV).
    private func makeChineseWAV() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let aiff = tmp.appendingPathComponent("vb-zh-\(UUID().uuidString).aiff")
        let wav = tmp.appendingPathComponent("vb-zh-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: aiff) }

        guard let voice = chineseSayVoice() else {
            throw XCTSkip("no Chinese `say` voice on this machine")
        }
        _ = try run(
            "/usr/bin/say",
            ["-v", voice, "-o", aiff.path, "今天天气很好，我们一起去公园散步吧，这是语音识别测试。"])
        _ = try run(
            "/usr/bin/afconvert",
            ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        let attrs = try? FileManager.default.attributesOfItem(atPath: wav.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > 1000 else { throw XCTSkip("`say` produced no audio") }
        return wav
    }

    /// A `zh_CN` `say` voice that actually synthesizes, or nil.
    ///
    /// `say -v ?` lists names with parenthetical descriptions ("Eddy (Chinese
    /// (China mainland))"), which `say -v` does not accept, so candidate simple
    /// names are tried until one produces audio.
    private func chineseSayVoice() -> String? {
        let candidates = ["Lanlan", "Han", "Tingting", "Meijia", "Sinji", "Eddy", "Flo"]
        let tmp = FileManager.default.temporaryDirectory
        for name in candidates {
            let probe = tmp.appendingPathComponent("vb-probe-\(UUID().uuidString).aiff")
            defer { try? FileManager.default.removeItem(at: probe) }
            _ = try? run("/usr/bin/say", ["-v", name, "-o", probe.path, "你好"])
            let attrs = try? FileManager.default.attributesOfItem(atPath: probe.path)
            if let bytes = attrs?[.size] as? Int, bytes > 1000 { return name }
        }
        return nil
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
