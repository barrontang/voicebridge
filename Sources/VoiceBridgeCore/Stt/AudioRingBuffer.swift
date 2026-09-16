import Foundation

/// Bounded float ring with **absolute** sample indexing. Extracting an
/// arbitrary time range is O(n) in the range length and allocation-free
/// apart from the output buffer.
struct AudioRingBuffer {
    private var storage: [Float]
    private var writeIndex = 0
    private var filled = 0
    private var absoluteWritten = 0           // total samples ever appended
    let sampleRate: Double
    let capacity: Int

    var startTime: TimeInterval { Double(absoluteWritten - filled) / sampleRate }
    var endTime:   TimeInterval { Double(absoluteWritten) / sampleRate }

    init(capacitySeconds: TimeInterval, sampleRate: Double = AudioFrame.sampleRate) {
        self.sampleRate = sampleRate
        self.capacity = Int(capacitySeconds * sampleRate)
        self.storage = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ frame: AudioFrame) {
        for s in frame.samples {
            storage[writeIndex] = s
            writeIndex = (writeIndex + 1) % capacity
            if filled < capacity { filled += 1 }
            absoluteWritten += 1
        }
    }

    /// Returns the requested slice, clamped to what's still retained.
    /// `nil` if the range has been fully evicted.
    func extract(_ range: Range<TimeInterval>) -> (samples: [Float], startTime: TimeInterval)? {
        let lo = max(range.lowerBound, startTime)
        let hi = min(range.upperBound, endTime)
        guard hi > lo else { return nil }

        let startSample = Int((lo * sampleRate).rounded())
        let endSample   = Int((hi * sampleRate).rounded())
        let length      = endSample - startSample
        guard length > 0 else { return nil }

        let oldestSample = absoluteWritten - filled
        var out = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let abs = startSample + i
            out[i] = storage[(abs - oldestSample + capacity) % capacity]
        }
        return (out, Double(startSample) / sampleRate)
    }
}
