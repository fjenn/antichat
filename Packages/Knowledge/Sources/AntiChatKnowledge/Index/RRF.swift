// Reciprocal rank fusion (Cormack, Clarke & Büttcher 2009): score(d) = Σ_lists 1 / (k + rank_list(d)), rank from 1.
// M2.T16 step 5: FTS5 bm25 top 50 ∪ vec0 KNN top 50, k = 60.
import Foundation

public enum RRF {
    public static let k = 60

    /// Fused order (best first; ties keep the order of first appearance).
    public static func fuse<Key: Hashable>(_ lists: [[Key]], k: Int = RRF.k) -> [(key: Key, score: Double)] {
        var score: [Key: Double] = [:]
        var first: [Key: Int] = [:]
        var n = 0
        for list in lists {
            for (i, key) in list.enumerated() {
                score[key, default: 0] += 1 / Double(k + i + 1)
                if first[key] == nil { first[key] = n; n += 1 }
            }
        }
        return score.map { (key: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : first[$0.key]! < first[$1.key]! }
    }
}
