import Foundation

/// A streaming 16-bit mono PCM WAV writer.
///
/// The one-shot `WAVWriter.write` needs the whole buffer in memory; this one
/// appends, so a two-hour recording is converted with a flat memory profile.
/// The RIFF sizes are patched when the file is finished, so the result is a
/// normal WAV (a truncated file is removed).
public final class WAVStreamWriter {

    public let url: URL
    private let sampleRate: Double
    private let file: FileHandle
    private var sampleCount: Int = 0
    private var isFinished = false

    /// Create the file and write a placeholder header.
    public init(url: URL, sampleRate: Double = AudioFrame.sampleRate) throws {
        self.url = url
        self.sampleRate = sampleRate

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            }
        // `FileHandle(forWritingAtPath:)` does not create the file.
        if !FileManager.default.createFile(atPath: url.path, contents: nil) {
            throw VoiceError.audioDecodeFailed(url: url.path,
                reason: "could not create the file for writing")
            }

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw VoiceError.audioDecodeFailed(url: url.path, reason: "could not open the file for writing")
            }
        self.file = handle

        // A placeholder header; the sizes are patched in `finish()`.
        try file.write(contentsOf: WAVStreamWriter.header(sampleRate: sampleRate, dataBytes: 0))
    }

    /// Append samples (in [-1, 1]).
    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty, !isFinished else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, Float(samples[i])))
            pcm[i] = Int16(clamped * 32_767.0)
        }
        try file.write(contentsOf: pcm.withUnsafeBytes { Data($0) })
        sampleCount += samples.count
    }

    /// Patch the header sizes and close the file.
    public func finish() throws {
        guard !isFinished else { return }
        isFinished = true
        let dataBytes = sampleCount * 2
        try file.seek(toOffset: 4)
        try file.write(contentsOf: WAVStreamWriter.u32(36 + UInt32(dataBytes)))
        try file.seek(toOffset: 40)
        try file.write(contentsOf: WAVStreamWriter.u32(UInt32(dataBytes)))
        try file.close()
    }

    /// Abort the write and delete the partial file.
    public func cancel() {
        guard !isFinished else { return }
        isFinished = true
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        if !isFinished { cancel() }
    }

    // MARK: - Header

    private static func u32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func u16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func header(sampleRate: Double, dataBytes: Int) -> Data {
        let bitsPerSample = 16
        let channels = 1
        let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        out.append(u32(36 + UInt32(dataBytes)))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        out.append(u32(16))
        out.append(u16(1))                          // PCM
        out.append(u16(UInt16(channels)))
        out.append(u32(UInt32(sampleRate)))
        out.append(u32(UInt32(byteRate)))
        out.append(u16(UInt16(blockAlign)))
        out.append(u16(UInt16(bitsPerSample)))
        out.append(contentsOf: Array("data".utf8))
        out.append(u32(UInt32(dataBytes)))
        return out
    }
}
