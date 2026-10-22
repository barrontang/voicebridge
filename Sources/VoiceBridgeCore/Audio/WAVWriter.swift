import Foundation

/// Minimal 16 kHz / mono / 16-bit PCM WAV writer.
///
/// It is hand-rolled on purpose: `AVAudioFile(forWriting:)` aborts inside a
/// bare CLI / sandboxed context, and a pure byte writer is trivially testable.
/// One implementation is shared by the live path, the push-to-talk recorder
/// and the windowed whisper adapter.
public enum WAVWriter {

    /// Write `samples` as a 16-bit mono PCM WAV and return the file URL.
    @discardableResult
    public static func write(
        samples: [Float],
        sampleRate: Double = AudioFrame.sampleRate,
        to url: URL
    ) throws -> URL {
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
        return url
    }
}
