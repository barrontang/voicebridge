import Foundation

/// Cross-version parsing for `whisper-cli` / whisper.cpp JSON output.
///
/// The output shape has drifted across releases, so `parseJSON` tolerates the
/// three forms seen in the wild:
///
///      1. ggerganov/whisper.cpp (newer):
///           { "language", "duration_ms",
///             "result": [ { "transcription", "offset", "duration", "language" } ] }
///      2. a flat object:
///           { "transcription", "language", "duration_ms",
///             "segments": [ { "transcription", "duration_ms" } ] }
///      3. a mixed object (some releases):
///           { "result": { "language" },
///             "transcription": [ { "text", "offsets": { "to" },
///                                  "timestamps": { "to" } } ] }
///
/// Text and language use a "first non-empty wins" ordering so the shapes never
/// double-count. Duration is the *maximum* of every end-time signal, in
/// milliseconds; bare `duration`, `duration_ms`, and `offsets.to` are all read
/// as milliseconds — only `timestamps.*` are clock strings (parsed to seconds).
public enum WhisperTranscriptParser {

        /// Metadata we can recover from a binary's output.
    public struct ParsedMetadata: Sendable, Equatable {
        public var text: String
        public var language: String           // detected language; "" when unknown
        public var durationSeconds: Double    // best-effort; 0 when unknown

        public init(text: String, language: String, durationSeconds: Double) {
            self.text = text
            self.language = language
            self.durationSeconds = durationSeconds
            }
        }

        /// Reads and trims a `-otxt` transcript file. Empty string if the file is
       /// absent or unopenable.
    public static func loadText(atPath path: String) -> String {
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return normalize(raw)
          }

        /// Extracts a transcript from `whisper-cli` stdout.
        ///
        /// Blank lines are dropped, and a terminal `"done."`/`"Done."` sentinel
        /// (printed by JSON-defaulting builds) is stripped, so that build's
        /// all-but-useless stdout never masquerades as a real transcript.
    public static func plainText(from stdout: String) -> String {
        let lines = stdout
                 .split(whereSeparator: \.isNewline)
                 .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                 .filter { !$0.isEmpty }
                 .filter {
                    let lower = $0.lowercased()
                    return lower != "done" && lower != "done."
                    }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
          }

        /// Parses a JSON report. Returns nil when the payload is not a recognised
        /// object.
        @discardableResult
    public static func parseJSON(_ data: Data) -> ParsedMetadata? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let record = obj as? [String: Any] else { return nil }

        let segments = segments(in: record)
        return ParsedMetadata(
            text: transcriptText(record, segments: segments),
            language: languageFor(record, segments: segments),
            durationSeconds: durationOf(record, segments: segments))
           }

        // MARK: - text / language / duration

        /// Whichever array-of-segments the payload uses, or nil.
    private static func segments(in record: [String: Any]) -> [[String: Any]]? {
          (record["result"] as? [[String: Any]])
          ?? (record["segments"] as? [[String: Any]])
          ?? (record["transcription"] as? [[String: Any]])
          }

        /// Concatenated, trimmed per-segment transcript.
    private static func transcriptText(_ record: [String: Any],
                                       segments: [[String: Any]]?) -> String {
        var pieces: [String] = []
        if let segments {
            for seg in segments {
                 // Prefer `transcription`, fall back to `text`, then empty.
                let raw = (seg["transcription"] as? String)
                          ?? (seg["text"] as? String)
                          ?? ""
                pieces.append(raw)
                  }
             }
          // Flat fallbacks, only when no segment array contributed.
        if pieces.isEmpty, let s = record["transcription"] as? String {
            pieces.append(s)
            }
        if pieces.isEmpty,
           let result = record["result"] as? [String: Any],
           let s = result["transcription"] as? String {
            pieces.append(s)
             }
        return pieces
                 .map { normalize($0) }
                 .filter { !$0.isEmpty }
                 .joined(separator: " ")
          }

        /// First non-empty language the payload reports, in precedence order.
    private static func languageFor(_ record: [String: Any],
                                    segments: [[String: Any]]?) -> String {
        if let l = record["language"] as? String, !l.isEmpty { return l }
        if let result = record["result"] as? [String: Any],
           let l = result["language"] as? String, !l.isEmpty { return l }
        if let params = record["params"] as? [String: Any],
           let l = params["language"] as? String, !l.isEmpty { return l }
        for seg in segments ?? [] {
            if let l = seg["language"] as? String, !l.isEmpty { return l }
              }
        return ""
          }

          /// Maximum of every end-time signal, in milliseconds, then ÷1000 to
        /// seconds. `duration`, `duration_ms`, and `offsets.to` are milliseconds;
        /// only `timestamps.*` are clock strings parsed to seconds.
    private static func durationOf(_ record: [String: Any],
                                   segments: [[String: Any]]?) -> Double {
        var maxMs = doubleValue(record["duration_ms"])
        maxMs = max(maxMs, doubleValue(record["duration"]))          // bare key: ms
        for seg in segments ?? [] {
            maxMs = max(maxMs, doubleValue(seg["duration_ms"]))
            maxMs = max(maxMs, doubleValue(seg["duration"]))         // ms
            if let offsets = seg["offsets"] as? [String: Any] {
                maxMs = max(maxMs, doubleValue(offsets["to"]))
                  }
            if let timestamps = seg["timestamps"] as? [String: Any],
               let to = timestamps["to"] as? String,
               let secs = parseTimestamp(to) {
                maxMs = max(maxMs, secs * 1000.0)
                  }
               }
        return maxMs / 1000.0
         }

        // MARK: - helpers

         /// "HH:MM:SS,msm" / "MM:SS,msm" / "SS" → seconds, or nil.
    private static func parseTimestamp(_ s: String) -> Double? {
        let parts = s
                  .replacingOccurrences(of: ",", with: ".")
                  .split(separator: ":")
                  .compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var seconds = 0.0
        for i in stride(from: parts.count, through: 1, by: -1) {
            seconds += parts[parts.count - i] * pow(60.0, Double(i - 1))
             }
        return seconds
         }

     private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         }

          /// JSON numbers can decode as either Int or Double; accept both.
    private static func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
         return 0
           }
}
