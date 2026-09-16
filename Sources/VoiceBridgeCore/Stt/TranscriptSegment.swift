import Foundation

public struct TranscriptSegment: Sendable, Identifiable, Equatable {
    public enum Stability: Sendable, Equatable {
        case volatile    // may be revised; render muted
        case stable      // immutable once emitted
    }

    public let id: UUID
    public let text: String
    /// Absolute audio time covered by this segment.
    public let range: Range<TimeInterval>
    public let stability: Stability
    public let confidence: Double?
    public let windowIndex: Int
    /// Ties volatile segments from successive windows to the same utterance,
    /// so SwiftUI can update in place instead of replace-and-flicker.
    public let utteranceID: UUID?

    public init(
        id: UUID = UUID(),
        text: String,
        range: Range<TimeInterval>,
        stability: Stability,
        confidence: Double? = nil,
        windowIndex: Int = 0,
        utteranceID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.range = range
        self.stability = stability
        self.confidence = confidence
        self.windowIndex = windowIndex
        self.utteranceID = utteranceID
    }
}

public enum TranscriptEvent: Sendable {
    case partial(TranscriptSegment)    // replace segment with same id
    case final(TranscriptSegment)      // promote; never changes again
    case gap(Range<TimeInterval>)      // audio dropped (backpressure / reset)
    case finished
}
