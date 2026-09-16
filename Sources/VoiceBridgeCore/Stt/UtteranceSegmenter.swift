import Foundation

/// Energy + zero-crossing VAD with hysteresis. Cheap enough to run on every
/// frame; good enough to gate inference on silence. Swap in Silero later if
/// you need robustness against non-stationary noise.
public struct UtteranceSegmenter: Sendable {

    public struct Config: Sendable {
        public var speechThreshold: Float = 0.012
        public var silenceThreshold: Float = 0.006       // hysteresis low-water
        public var trailingSilence: TimeInterval = 0.6
        public var minimumUtterance: TimeInterval = 0.25
        public var maximumUtterance: TimeInterval = 15.0   // force-chunk monologues
        public var leadIn: TimeInterval = 0.20             // pre-roll for context

        public init() {}
    }

    public enum Boundary: Sendable {
        case started(at: TimeInterval)
        case continuing
        case ended(range: Range<TimeInterval>)
    }

    public var config: Config
    private var state: State = .idle
    private var silenceAccum: TimeInterval = 0
    /// Set while an utterance is open; carried into segments so the UI
    /// can diff volatile updates in place.
    public private(set) var currentUtteranceID: UUID?

    private enum State { case idle; case speaking(start: TimeInterval) }

    public init(config: Config = Config()) { self.config = config }

    public mutating func consume(_ frame: AudioFrame) -> [Boundary] {
        let rms = Self.rms(frame.samples)
        var out: [Boundary] = []

        switch state {
        case .idle:
            if rms >= config.speechThreshold {
                let start = max(0, frame.startTime - config.leadIn)
                state = .speaking(start: start)
                silenceAccum = 0
                currentUtteranceID = UUID()
                out.append(.started(at: start))
            }

        case .speaking(let start):
            if rms < config.silenceThreshold { silenceAccum += frame.duration }
            else                               { silenceAccum = 0 }

            let elapsed   = frame.endTime - start
            let closed    = silenceAccum >= config.trailingSilence
            let hardCap   = elapsed >= config.maximumUtterance

            if closed || hardCap {
                let end = frame.endTime - silenceAccum
                let range = start..<max(end, start + 0.01)
                out.append(.ended(range: range))
                state = .idle
                silenceAccum = 0
                // Keep currentUtteranceID set until the engine finalises.
            } else {
                out.append(.continuing)
            }
        }
        return out
    }

    /// Force-close on stop / pause.
    public mutating func flush(at time: TimeInterval) -> Boundary? {
        guard case .speaking(let start) = state else { return nil }
        state = .idle
        silenceAccum = 0
        return .ended(range: start..<time)
    }

    static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var a: Float = 0
        for x in s { a += x * x }
        return (a / Float(s.count)).squareRoot()
    }
}
