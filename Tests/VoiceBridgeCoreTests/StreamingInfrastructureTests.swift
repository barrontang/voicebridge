import XCTest
@testable import VoiceBridgeCore

// MARK: - AudioRingBuffer

final class AudioRingBufferTests: XCTestCase {

    func testAppendAndExtractInRange() {
        var ring = AudioRingBuffer(capacitySeconds: 1.0)   // 16 000 samples
         // Write 0.5 s of 1.0-valued samples.
        ring.append(AudioFrame(
            samples: [Float](repeating: 1.0, count: 8000),
            startTime: 0, sequence: 0))

        let slice = ring.extract(0.0..<0.5)
        XCTAssertNotNil(slice)
        XCTAssertEqual(slice!.samples.count, 8000)
        XCTAssertEqual(slice!.samples[0], 1.0, accuracy: 0.001)
     }

    func testExtractNilWhenEvicted() {
        var ring = AudioRingBuffer(capacitySeconds: 1.0)
          // Write 2 s total (32 000 samples) → the first 1 s is evicted.
        ring.append(AudioFrame(
            samples: [Float](repeating: 1.0, count: 32000),
            startTime: 0, sequence: 0))
          // Ask for the evicted portion.
        XCTAssertNil(ring.extract(0.0..<0.5))
     }

    func testTimeWindowTracksTotal() {
        var ring = AudioRingBuffer(capacitySeconds: 1.0)
        let before = ring.endTime
        ring.append(AudioFrame(
            samples: [Float](repeating: 0.5, count: 1600),
            startTime: before, sequence: 0))
        XCTAssertEqual(ring.endTime, before + 0.1, accuracy: 0.001)
     }

    func testEmptyExtractReturnsNil() {
        let ring = AudioRingBuffer(capacitySeconds: 1.0)
        XCTAssertNil(ring.extract(0..<0))
     }
}

// MARK: - WAVWriter

final class WAVWriterTests: XCTestCase {

    func testWAVWriterProducesValidHeader() throws {
        let url = FileManager.default.temporaryDirectory
             .appendingPathComponent("vb-wavwriter-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: url)

        let samples = (0..<1600).map { Float(sin(Double($0) * 0.01)) * 0.25 }
        try WAVWriter.write(samples: samples, to: url)
        let data = try Data(contentsOf: url)

         // RIFF / WAVE header
        XCTAssertEqual(Array(data[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(data.count, 44 + 1600 * 2)
        XCTAssertEqual(Array(data[8..<12]), Array("WAVE".utf8))
        XCTAssertEqual(Array(data[12..<16]), Array("fmt ".utf8))
        XCTAssertEqual(Array(data[36..<40]), Array("data".utf8))

        func u16(_ off: Int) -> UInt16 {
            UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
         }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | (UInt32(data[off + 1]) << 8)
             | (UInt32(data[off + 2]) << 16) | (UInt32(data[off + 3]) << 24)
         }
        XCTAssertEqual(u16(20), 1)           // PCM
        XCTAssertEqual(u16(22), 1)           // mono
        XCTAssertEqual(u32(24), 16000)       // 16 kHz
        XCTAssertEqual(u16(34), 16)          // 16-bit

        try? FileManager.default.removeItem(at: url)
     }

    func testWAVWriterEmptySamples() throws {
        let url = FileManager.default.temporaryDirectory
             .appendingPathComponent("vb-wavwriter-empty-\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: url)
        try WAVWriter.write(samples: [], to: url)
        let data = try Data(contentsOf: url)
          // 44-byte header, 0 bytes of data.
        XCTAssertEqual(data.count, 44)
        try? FileManager.default.removeItem(at: url)
     }
}

// MARK: - AudioFrame

final class AudioFrameTests: XCTestCase {

    func testDurationAndEndTime() {
        let frame = AudioFrame(
            samples: [Float](repeating: 0.1, count: 1600),
            startTime: 1.0, sequence: 42)
        XCTAssertEqual(frame.duration, 0.1, accuracy: 0.0001)
        XCTAssertEqual(frame.endTime, 1.1, accuracy: 0.0001)
        XCTAssertEqual(frame.sequence, 42)
        XCTAssertEqual(AudioFrame.sampleRate, 16_000)
     }
}
