import XCTest
@testable import VoiceBridgeCore

/// Smoke tests for the pure-logic parts of the core. Audio/shell parts are
/// integration-tested by `voicebridge-cli`'s `ping`/`stt`/`tts`, not unit-tested
/// here (they need a mic and an installed binary).
final class CoreTests: XCTestCase {
     // --- SttModel -----------------------------------------------------------
    func testSttModelLabelsAndFilenames() {
        XCTAssertEqual(SttModel.largeV3Turbo.ggmlFilename, "ggml-large-v3-turbo.bin")
        XCTAssertTrue(SttModel.largeV3Turbo.label.contains("RECOMMENDED"))
          // tiny, base, small, medium, large-v3-turbo, large-v3
        XCTAssertEqual(SttModel.allCases.count, 6)
        XCTAssertEqual(SttModel.largeV3.ggmlFilename, "ggml-large-v3.bin")
         }

    func testTTSModes() {
        XCTAssertEqual(TTSMode.piper.rawValue, "Piper (local, DEFAULT)")
        XCTAssertEqual(TTSMode.system.rawValue, "Built-in (offline)")
         }

    func testURLHelpers() {
          // appendingIsDirectory() sets the URL's *directory flag* (not a
          // filesystem query), so assert hasDirectoryPath.
        let url = URL(fileURLWithPath: "/a/b/c").appendingIsDirectory()
        XCTAssertTrue(url.hasDirectoryPath)

        XCTAssertEqual("en_US-lessac-medium.onnx".lastPathComponentWithoutSuffix,
                         "en_US-lessac-medium")
         }

    func testVoiceErrorFormatting() {
        let e = VoiceError.modelMissing(model: "ggml-large-v3-turbo.bin", directory: "/tmp/m")
        XCTAssertNotNil(e.errorDescription)
        XCTAssertTrue(e.errorDescription!.contains("ggml-large-v3-turbo.bin"))
          }

     // --- WhisperTranscriptParser: cross-version output ----------------------

      // A JSON-defaulting binary prints only terminal sentinels on stdout.
    func testParserPlainTextDropsDoneSentinel() {
        XCTAssertEqual(WhisperTranscriptParser.plainText(from: "Done."), "")
        XCTAssertEqual(WhisperTranscriptParser.plainText(from: "done."), "")
        XCTAssertEqual(WhisperTranscriptParser.plainText(from: "done"), "")
        XCTAssertEqual(WhisperTranscriptParser.plainText(from: "hello world\n"), "hello world")
        XCTAssertEqual(
            WhisperTranscriptParser.plainText(from: "line one\n\nline two\ndone."),
              "line one\nline two")
          }

      // Shape 1: top-level duration_ms is authoritative over per-segment values,
       // so the total is not double-counted.
    func testParserGgerganovJSON() {
        let json = """
          {
            "language": "en",
            "duration_ms": 3500,
            "result": [
              { "transcription": "hello ", "language": "en", "offset": 0, "duration": 1500 },
              { "transcription": "world", "language": "en", "offset": 1500, "duration": 2000 }
            ]
          }
          """
        let meta = WhisperTranscriptParser.parseJSON(Data(json.utf8))
        XCTAssertEqual(meta?.text, "hello world")
        XCTAssertEqual(meta?.language, "en")
        XCTAssertEqual(meta?.durationSeconds ?? 0, 3.5, accuracy: 0.0001)
          }

      // Shape 2: no top-level duration → sum the per-segment duration_ms.
    func testParserFallsBackToSegmentDurations() {
        let json = """
          {
            "segments": [
              { "transcription": "a", "language": "zh", "duration_ms": 800 },
              { "transcription": "b", "duration_ms": 1200 }
          ]
          }
          """
        let meta = WhisperTranscriptParser.parseJSON(Data(json.utf8))
        XCTAssertEqual(meta?.text, "a b")
        XCTAssertEqual(meta?.language, "zh")
        // max per-segment end = 1200 ms; no top-level duration.
        XCTAssertEqual(meta?.durationSeconds ?? 0, 1.2, accuracy: 0.0001)
          }

      // Shape 3: `result` is an object ({language}); the transcript lives in a
      // top-level `transcription[]` with offsets (ms) that the model reports as
      // its 30 s context window.
    func testParserMixedShape() {
        let json = """
          {
            "params": { "model": "m.bin", "language": "en", "translate": false },
            "result": { "language": "en" },
            "transcription": [
              {
                 "timestamps": { "from": "00:00:00,000", "to": "00:00:30,000" },
                 "offsets": { "from": 0, "to": 30000 },
                 "text": " the quick brown fox jumps over the lazy dog."
              }
            ]
          }
          """
        let meta = WhisperTranscriptParser.parseJSON(Data(json.utf8))
        XCTAssertEqual(meta?.text, "the quick brown fox jumps over the lazy dog.")
        XCTAssertEqual(meta?.language, "en")
        XCTAssertEqual(meta?.durationSeconds ?? 0, 30.0, accuracy: 0.0001)
          }

      // A flat object with a single string transcript and language.
    func testParserFlatString() {
        let json = """
          { "transcription": "just words", "language": "fr", "duration_ms": 1000 }
          """
        let meta = WhisperTranscriptParser.parseJSON(Data(json.utf8))
        XCTAssertEqual(meta?.text, "just words")
        XCTAssertEqual(meta?.language, "fr")
        XCTAssertEqual(meta?.durationSeconds ?? 0, 1.0, accuracy: 0.0001)
          }

    func testParserRejectsNonJSON() {
        XCTAssertNil(WhisperTranscriptParser.parseJSON(Data("not json".utf8)))
          }

      // -otxt files carry trailing whitespace; loadText must normalise it. A
       // missing file yields "" rather than throwing.
    func testParserLoadTextFromFile() throws {
        let file = FileManager.default.temporaryDirectory
                       .appendingPathComponent("vb-\(UUID().uuidString).txt")
        try "  hello world    \n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(WhisperTranscriptParser.loadText(atPath: file.path), "hello world")
        XCTAssertEqual(WhisperTranscriptParser.loadText(atPath: "/no/such/file.txt"), "")
          }

          // --- StreamingSttController.writeWAV16 (regression for the live-STT crash) ---
       /// The live path previously crashed inside AVAudioFile.write; it now writes
       /// a pure byte-level 16-bit PCM WAV. Verify the header + sample bytes.
      @MainActor
      func testWriteWAV16ProducesValidHeader() throws {
            let url = FileManager.default.temporaryDirectory
                                .appendingPathComponent("vb-writeWAV16-\(UUID().uuidString).wav")
            try? FileManager.default.removeItem(at: url)
          // 0.5 s at 16 kHz -> 8000 samples
           let samples = (0..<8000).map { Float(sin(Double($0) * 0.01)) * 0.25 }
            try StreamingSttController.writeWAV16(samples, to: url)
            let data = try Data(contentsOf: url)

            // RIFF / WAVE header
           XCTAssertEqual(Array(data[0..<4]), Array("RIFF".utf8))
           XCTAssertEqual(data.count, 44 + 8000 * 2)           // 44-byte header + 16-bit PCM
           XCTAssertEqual(Array(data[8..<12]), Array("WAVE".utf8))
           XCTAssertEqual(Array(data[12..<16]), Array("fmt ".utf8))
            XCTAssertEqual(Array(data[36..<40]), Array("data".utf8))

            // PCM / mono / 16 kHz / 16-bit
           func u16(_ off: Int) -> UInt16 {
             UInt16(data[off]) | (UInt16(data[off + 1]) << 8) }
            func u32(_ off: Int) -> UInt32 {
              UInt32(data[off]) | (UInt32(data[off + 1]) << 8)
             | (UInt32(data[off + 2]) << 16) | (UInt32(data[off + 3]) << 24) }
           XCTAssertEqual(u16(20), 1)         // audio format = PCM
           XCTAssertEqual(u16(22), 1)         // mono
           XCTAssertEqual(u32(24), 16000)     // sample rate
           XCTAssertEqual(u16(34), 16)        // bits per sample
           }

         // --- StreamingSttController.deltaSince (live-append, not rewrite) ---
        /// A fresh tick appends only the NEW words; a no-change tick appends nothing.
       @MainActor
     func testDeltaSinceAppendsNewWordsOnly() {
          // First tick: old empty -> whole thing is new.
      XCTAssertEqual(StreamingSttController.deltaSince("", full: "hello"), "hello")
          // Second tick: same text -> nothing new.
       XCTAssertEqual(StreamingSttController.deltaSince("hello", full: "hello"), "")
          // Third tick: a longer full -> only the tail after the old prefix.
      XCTAssertEqual(StreamingSttController.deltaSince("hello", full: "hello world"), "world")
          // A drifted prefix should still yield only the remainder.
       XCTAssertEqual(StreamingSttController.deltaSince("hello wor", full: "hello worg"), "g")
          // Empty full -> empty.
      XCTAssertEqual(StreamingSttController.deltaSince("hello xxx", full: ""), "")
        }
       }
