import Foundation

/// Energy + zero-crossing VAD with hysteresis. Cheap enough to run on every
/// frame; good enough to gate inference on silence. Swap in Silero later if
/// you need robustness against non-stationary noise.
public struct UtteranceSegmenter: Sendable {

    public struct Config: Sendable {
        public var speechThreshold: Float = 0.012
        public var silenceThreshold: Float = 0.006  // hysteresis low-water
        /// Silence that closes an utterance.
        ///
        /// 0.6 s cut people off at ordinary clause boundaries, so whisper saw
        /// fragments with no sentence context (the "live is less accurate than
        /// push-to-talk" report). 1 s keeps a sentence together and is still
        /// fast enough for captions.
        public var trailingSilence: TimeInterval = 1.0
        public var minimumUtterance: TimeInterval = 0.25
        /// Force-chunk monologues. 30 s matches whisper's own window, so a
        /// long turn is decoded in one pass instead of two half sentences.
        public var maximumUtterance: TimeInterval = 30.0
        public var leadIn: TimeInterval = 0.30  // pre-roll for context

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
    /// When the open utterance started (absolute capture time), or nil when
    /// no utterance is open. The live engine transcribes
    /// `currentUtteranceStart..<now` for its partial pass, so the caption
    /// covers the *whole* sentence rather than an arbitrary window.
    public private(set) var currentUtteranceStart: TimeInterval?

    private enum State {
        case idle
        case speaking(start: TimeInterval)
    }

    /// Set when the previous utterance was cut by `maximumUtterance` rather than
    /// by silence. The next utterance then starts *exactly* at the current frame
    /// instead of re-adding `leadIn` — that pre-roll is audio the previous
    /// utterance already transcribed, and re-feeding it produced a duplicated
    /// (or, once the watermark dropped it, a swallowed) word at every 15 s seam.
    private var reopenWithoutLeadIn = false

    public init(config: Config = Config()) { self.config = config }

    public mutating func consume(_ frame: AudioFrame) -> [Boundary] {
        let rms = Self.rms(frame.samples)
        var out: [Boundary] = []

        switch state {
        case .idle:
            if rms >= config.speechThreshold {
                let start =
                    reopenWithoutLeadIn
                    ? frame.startTime
                    : max(0, frame.startTime - config.leadIn)
                reopenWithoutLeadIn = false
                state = .speaking(start: start)
                silenceAccum = 0
                currentUtteranceID = UUID()
                currentUtteranceStart = start
                out.append(.started(at: start))
            }

        case .speaking(let start):
            if rms < config.silenceThreshold {
                silenceAccum += frame.duration
            } else {
                silenceAccum = 0
            }

            let elapsed = frame.endTime - start
            let closed = silenceAccum >= config.trailingSilence
            let hardCap = elapsed >= config.maximumUtterance

            if closed || hardCap {
                let end = frame.endTime - silenceAccum
                let range = start..<max(end, start + 0.01)
                out.append(.ended(range: range))
                state = .idle
                silenceAccum = 0
                // A forced cut (not silence) must not re-feed the pre-roll.
                reopenWithoutLeadIn = hardCap
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
        currentUtteranceStart = nil
        reopenWithoutLeadIn = false
        return .ended(range: start..<time)
    }

    static func rms(_ s: [Float]) -> Float {
        guard !s.isEmpty else { return 0 }
        var a: Float = 0
        for x in s { a += x * x }
        return (a / Float(s.count)).squareRoot()
    }
}
