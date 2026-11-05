import Foundation

/// Word-level comparison of an ASR sentence with its proposed correction.
///
/// The point of the diff is *scale*, not rendering: it tells the policy how much
/// of the sentence a model wants to change. A homophone fix touches one word; a
/// "correction" that rewrites half the sentence is a paraphrase and must be
/// rejected.
public enum WordDiff {

    public struct Result: Sendable, Equatable {
        public let changed: Int
        public let total: Int
        /// Fraction of the original that changed (0…1).
        public var ratio: Double {
            total == 0 ? 0 : Double(changed) / Double(total)
        }
    }

    public static func compare(_ original: String, _ corrected: String) -> Result {
        let a = tokens(original)
        let b = tokens(corrected)
        guard !a.isEmpty else { return Result(changed: 0, total: 0) }
        // Levenshtein, not LCS: replacing one word must count as *one* change.
        // An LCS-based count charges a replacement twice (delete + insert), so
        // "tree" → "three" in a five-word sentence looked like a 40 % rewrite.
        let changed = min(a.count, editDistance(a, b))
        return Result(changed: changed, total: a.count)
    }

    /// Words for space-delimited text, characters for scripts written without
    /// spaces (Chinese, Japanese, Korean). Without this, a Chinese sentence is
    /// one "word" and every correction looks like a 100 % rewrite.
    static func tokens(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if isMostlyCJK(trimmed) {
            return trimmed.filter { !$0.isWhitespace }.map(String.init)
        }
        return trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func isMostlyCJK(_ text: String) -> Bool {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                0xF900...0xFAFF, 0xFF66...0xFF9D, 0x20000...0x2FA1F:
                cjk += 1
            case 0x41...0x5A, 0x61...0x7A:
                latin += 1
            default:
                break
            }
        }
        return cjk > latin
    }

    /// Levenshtein distance over tokens: insert, delete and substitute all
    /// cost one. Sentences are tens of tokens, so O(n·m) is irrelevant next to
    /// the model call that produced the correction.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,  // delete
                    current[j - 1] + 1,  // insert
                    previous[j - 1] + cost  // substitute
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}

/// Decides whether a proposed correction may be applied.
///
/// A corrector is a language model: it can hallucinate, translate, or "improve"
/// a sentence into something the speaker never said. The policy is the guard
/// rail — any doubt means the transcript keeps whisper's words.
public enum CorrectionPolicy {

    public struct Decision: Sendable, Equatable {
        public let accepted: Bool
        public let reason: String

        public static let accept = Decision(accepted: true, reason: "accepted")
        static func reject(_ reason: String) -> Decision {
            Decision(accepted: false, reason: reason)
        }
    }

    /// Largest fraction of a sentence a corrector may touch. One or two words
    /// in a short sentence already sits near this; a real paraphrase exceeds it.
    public static let maximumChangedRatio = 0.34
    /// How much the corrected sentence may grow or shrink.
    public static let allowedLengthRatio = 0.6...1.5

    public static func evaluate(original: String, corrected: String) -> Decision {
        let a = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return .reject("empty") }
        guard a != b else { return .reject("unchanged") }

        let lengthRatio = Double(b.count) / Double(max(a.count, 1))
        guard allowedLengthRatio.contains(lengthRatio) else {
            return .reject("length \(String(format: "%.2f", lengthRatio))×")
        }

        // A correction keeps the language. A model that "helpfully" translates
        // the sentence — or answers in the context's language — is rejected.
        guard WordDiff.isMostlyCJK(a) == WordDiff.isMostlyCJK(b) else {
            return .reject("script changed")
        }

        let diff = WordDiff.compare(a, b)
        guard diff.ratio <= maximumChangedRatio else {
            return .reject("too many edits (\(String(format: "%.0f", diff.ratio * 100)) %)")
        }

        return .accept
    }
}
