// M2.T16 step 4: finished message text → chunks of ≤ 512 tokens. The tokenizer lives in the helper, so the cut uses
// the ~4 characters/token English estimate with headroom (1,800 characters ≈ 450 tokens) and prefers paragraph, then
// sentence, then word boundaries. The helper truncates at 512 tokens as the hard guard (EmbeddingService.maxTokens).
import Foundation

public enum Chunker {
    public static let maxChars = 1_800

    public static func chunks(_ text: String, maxChars: Int = Chunker.maxChars) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        for unit in units(trimmed, maxChars: maxChars) {
            if current.count + unit.count + 1 > maxChars { flush() }
            current += current.isEmpty ? unit : " " + unit
        }
        flush()
        return out
    }

    /// Paragraphs, split further into sentences and words when one is longer than `maxChars`.
    static func units(_ text: String, maxChars: Int) -> [String] {
        var out: [String] = []
        for para in text.components(separatedBy: "\n\n") where !para.isEmpty {
            if para.count <= maxChars { out.append(para); continue }
            var sentences: [String] = []
            para.enumerateSubstrings(in: para.startIndex..., options: .bySentences) { s, _, _, _ in
                if let s { sentences.append(s) }
            }
            for s in sentences {
                if s.count <= maxChars { out.append(s); continue }
                var piece = ""
                for w in s.split(separator: " ", omittingEmptySubsequences: true) {
                    if piece.count + w.count + 1 > maxChars, !piece.isEmpty { out.append(piece); piece = "" }
                    piece += piece.isEmpty ? String(w.prefix(maxChars)) : " " + w
                }
                if !piece.isEmpty { out.append(piece) }
            }
        }
        return out
    }
}
