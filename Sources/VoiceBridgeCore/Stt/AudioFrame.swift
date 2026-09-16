import Foundation

/// A block of mono PCM at the canonical format (16 kHz, Float32).
/// `startTime` is absolute since capture-session start and monotonic.
public struct AudioFrame: Sendable {
    public static let sampleRate: Double = 16_000

    public let samples: [Float]
    public let startTime: TimeInterval
    public let sequence: UInt64

    public var duration: TimeInterval { Double(samples.count) / Self.sampleRate }
    public var endTime: TimeInterval { startTime + duration }

    public init(samples: [Float], startTime: TimeInterval, sequence: UInt64) {
        self.samples = samples
        self.startTime = startTime
        self.sequence = sequence
    }
}
