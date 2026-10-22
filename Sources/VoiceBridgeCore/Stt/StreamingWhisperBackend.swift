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
            // Timestamps are requested on purpose: the JSON's per-segment
            // offsets are what lets the reconciler drop the overlap between
            // two windows instead of guessing with word matching.
            useTimestamps: true
        )

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let windowDuration = Double(samples.count) / sampleRate

        // Preferred: the engine's own per-segment timings, shifted into the
        // window's absolute time base.
        if !result.segments.isEmpty {
            return result.segments.map { seg in
                let lower = startTime + seg.start
                let upper = startTime + seg.end
                return TranscriptSegment(
                    text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    range: lower..<max(upper, lower + 0.01),
                    stability: hint == .final ? .stable : .volatile
                )
            }
        }

        // Fallback (an engine without timings): one segment for the window.
        return [
            TranscriptSegment(
                text: text,
                range: startTime..<(startTime + windowDuration),
                stability: hint == .final ? .stable : .volatile
            )
        ]
    }
}
