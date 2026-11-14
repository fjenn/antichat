// M7.T03 step 3 (R-080 AC3; blueprint B §B1.2 step 2): the queries of one `web_search` step. With the Web search chip
// on, the first step goes out with `tool_choice = web_search`, which is the grammar-constrained JSON call (llama-server
// `required` over that one tool, MLX a grammar that opens the call at once, M2.T22): the model writes
// `{"queries": [...]}` and nothing else. Without the chip the model decides. Either way the plan is normalised here:
// trimmed, de-duplicated (case-insensitive), at most `maxQueries` (the tier's `search.queries`), each ≤ 200 characters.
// When the call carries no usable query the user's own words are the query (only search words leave the Mac).
import Foundation

public struct SearchPlan: Sendable, Equatable {
    public var queries: [String]
    public var freshness: String?
    public var category: String?

    public static let maxQueryLength = 200

    public init(queries: [String], freshness: String? = nil, category: String? = nil) {
        self.queries = queries; self.freshness = freshness; self.category = category
    }

    /// The step's plan from the call's arguments; `fallback` (the user's message) when no query survives.
    public static func make(arguments json: String, maxQueries: Int, fallback: String? = nil) -> SearchPlan? {
        struct Args: Decodable { var queries: [String]?; var query: String?; var freshness: String?; var category: String? }
        let a = try? JSONDecoder().decode(Args.self, from: Data(json.utf8))
        var raw = a?.queries ?? []
        if let q = a?.query { raw.insert(q, at: 0) }  // a model that wrote the singular form
        var seen = Set<String>(), out: [String] = []
        for q in raw {
            let t = String(q.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQueryLength))
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count >= max(1, maxQueries) { break }
        }
        if out.isEmpty, let f = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty {
            out = [String(f.prefix(maxQueryLength))]
        }
        guard !out.isEmpty else { return nil }
        let fresh = a?.freshness.flatMap { ["day", "week", "month", "any"].contains($0) ? $0 : nil }
        let cat = a?.category.flatMap { ["general", "news"].contains($0) ? $0 : nil }
        return SearchPlan(queries: out, freshness: fresh, category: cat)
    }
}
