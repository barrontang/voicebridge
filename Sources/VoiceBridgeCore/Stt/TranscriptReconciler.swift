import Foundation

/// Merges overlapping hypotheses from successive windows.
/// Invariant: once a segment is `.stable`, its `text` and `range` never change.
struct TranscriptReconciler {

    private(set) var committed: [TranscriptSegment] = []
    private var volatileTail: [TranscriptSegment] = []
    /// Highest audio time covered by a stable segment. Anything starting
    /// before this is a re-emission of already-committed audio.
    private var watermark: TimeInterval = 0

    /// Tolerance when comparing a new segment against the watermark.
    /// Whisper's segment timestamps are typically ±50 ms; 80 ms avoids
    /// both false dedupe and duplicate emissions at the seam.
    private let watermarkTolerance: TimeInterval = 0.08

    mutating func ingest(
        segments: [TranscriptSegment],
        windowRange: Range<TimeInterval>,
        windowIndex: Int,
        utteranceID: UUID?
    ) -> [TranscriptEvent] {
        var events: [TranscriptEvent] = []

        // 1. Drop re-emissions of already-committed audio.
        let fresh = segments.filter { $0.range.lowerBound >= watermark - watermarkTolerance }

        // 2. A segment whose midpoint falls before the window's close will
        //    not be revised — we always carry `overlap` seconds of left
        //    context, so the next window re-covers it fully.
        let commitHorizon = windowRange.upperBound
        var newStable: [TranscriptSegment] = []
        var newVolatile: [TranscriptSegment] = []

        for seg in fresh {
            let mid = (seg.range.lowerBound + seg.range.upperBound) / 2
            let stable = mid < commitHorizon
            let normalised = TranscriptSegment(
                id: seg.id,
                text: seg.text,
                range: seg.range,
                stability: stable ? .stable : .volatile,
                confidence: seg.confidence,
                windowIndex: windowIndex,
                utteranceID: utteranceID
            )
            if stable { newStable.append(normalised) } else { newVolatile.append(normalised) }
        }

        newStable.sort { $0.range.lowerBound < $1.range.lowerBound }
        newVolatile.sort { $0.range.lowerBound < $1.range.lowerBound }

        // 3. Emit.
        for seg in newStable {
            committed.append(seg)
            watermark = max(watermark, seg.range.upperBound)
            events.append(.final(seg))
        }
        for seg in newVolatile {
            events.append(.partial(seg))
        }

        // 4. Retire volatile segments that weren't re-emitted this window.
        //     (Whisper may merge two short segments into one; the old ids
        //    simply disappear. The VM handles removal.)
        volatileTail = newVolatile

        return events
    }

    var snapshot: [TranscriptSegment] { committed + volatileTail }

    mutating func reset() {
        committed.removeAll()
        volatileTail.removeAll()
        watermark = 0
    }
}
