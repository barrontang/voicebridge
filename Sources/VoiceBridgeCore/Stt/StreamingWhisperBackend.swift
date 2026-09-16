import Foundation

public enum StreamingHint: Sendable { case partial, final }

public protocol StreamingWhisperBackend: Sendable {
    func transcribe(
        samples: [Float],
        sampleRate: Double,
        startTime: TimeInterval,
        model: String,
        language: String?,
        hint: StreamingHint
    ) async throws -> [TranscriptSegment]
}

// MARK: - Waveform writer helper

/// Minimal 16 kHz / mono / 16-bit PCM WAV writer used by the windowed
/// adapter.  Extracted from `StreamingSttController.writeWAV16` so both
/// the legacy controller and the new engine share one implementation.
public enum WAVWriter {
    public static func write(
        samples: [Float],
        sampleRate: Double = AudioFrame.sampleRate,
        to url: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let bitsPerSample = 16
        let channels = 1
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * blockAlign
        var out = Data()

        func u32(_ v: UInt32) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
        }
        func u16(_ v: UInt16) {
            var x = v.littleEndian
            withUnsafeBytes(of: &x) { out.append(contentsOf: $0) }
        }

        out.append(contentsOf: Array("RIFF".utf8))
        u32(36 + UInt32(dataBytes))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitsPerSample))
        out.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))

        var samples16 = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, Float(samples[i])))
            samples16[i] = Int16(clamped * 32_767.0)
        }
        out.append(contentsOf: samples16.withUnsafeBytes { Array($0) })
        try out.write(to: url)
    }
}

// MARK: - Windowed adapter

/// Wraps the existing file-based `WhisperBackend` so live mode works today.
/// Each window is a full process spawn — that's the reason `partialInterval`
/// defaults to 1.2 s. Correct, not fast. Replace with an in-process backend
/// (whisper.spm / SwiftWhisper) once App Sandbox support is required.
public struct WindowedWhisperAdapter: StreamingWhisperBackend {
    let fileBackend: any WhisperBackend
    let scratchDir: URL

    public init(fileBackend: any WhisperBackend,
                scratchDir: URL = FileManager.default.temporaryDirectory) {
        self.fileBackend = fileBackend
        self.scratchDir = scratchDir
    }

    public func transcribe(
        samples: [Float], sampleRate: Double, startTime: TimeInterval,
        model: String, language: String?, hint: StreamingHint
    ) async throws -> [TranscriptSegment] {

        let url = scratchDir.appendingPathComponent("vb-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try WAVWriter.write(samples: samples, sampleRate: sampleRate, to: url)

        // Map the model name string to the enum the file-based backend expects.
        let sttModel: SttModel
        if let match = SttModel.allCases.first(where: { $0.rawValue == model }) {
            sttModel = match
        } else {
            sttModel = .largeV3Turbo
        }

        let result = try await fileBackend.transcribe(
            audio: url,
            language: language,
            model: sttModel,
            useTimestamps: false
        )

        // The CLI backend returns a single flat transcription; wrap it in one
        // segment spanning the full window.
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let windowDuration = Double(samples.count) / sampleRate
        return [
            TranscriptSegment(
                text: text,
                range: startTime..<(startTime + windowDuration),
                stability: hint == .final ? .stable : .volatile
            )
        ]
    }
}
