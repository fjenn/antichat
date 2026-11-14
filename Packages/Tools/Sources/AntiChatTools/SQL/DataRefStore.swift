// M6.T08 step 4 (R-272): per-chat result handles. Every `query_data` result (all rows up to 100,000, not just the 200
// the model sees) is kept as `qr_<uuid>` → columns + types + rows (text; NULL = nil). M6.T10 `export_table` /
// `create_spreadsheet` and M6.T12 `create_chart` read them by `data_ref`. In memory only (incognito-safe), dropped
// with the chat's DuckDB store.
import Foundation

public struct DataRef: Sendable, Equatable {
    public var id: String
    public var sql: String
    public var columns: [String]
    /// DuckDB type names per column (BIGINT, DOUBLE, DATE, VARCHAR …).
    public var types: [String]
    public var rows: [[String?]]
    /// More rows existed than `DataRefStore.maxRows`.
    public var truncated: Bool

    public init(id: String, sql: String, columns: [String], types: [String], rows: [[String?]], truncated: Bool) {
        self.id = id; self.sql = sql; self.columns = columns; self.types = types; self.rows = rows; self.truncated = truncated
    }
}

public final class DataRefStore: @unchecked Sendable {
    public static let maxRows = 100_000
    /// M6 review #5: a chat keeps its most recent results only (each can hold 100,000 rows of text).
    public static let maxRefsPerChat = 20
    public static let shared = DataRefStore()
    private let lock = NSLock()
    private var refs: [String: [String: DataRef]] = [:]  // chat → id → ref
    private var order: [String: [String]] = [:]  // chat → ids, oldest first

    public init() {}

    public func put(chatID: String, _ ref: DataRef) {
        lock.lock(); defer { lock.unlock() }
        if refs[chatID]?[ref.id] == nil { order[chatID, default: []].append(ref.id) }
        refs[chatID, default: [:]][ref.id] = ref
        while let ids = order[chatID], ids.count > Self.maxRefsPerChat {
            refs[chatID]?[ids[0]] = nil
            order[chatID]?.removeFirst()
        }
    }

    /// The chat's result for `id`. A mistyped handle (a model truncating or slipping a character of the 36-char UUID)
    /// resolves only when it points at exactly one of this chat's handles: a unique prefix (≥ 8 hex chars after
    /// `qr_`), or edit distance ≤ 2 to one handle while every other is ≥ 3 further away. Anything else stays nil (the
    /// tool reports "no query result"), so a hallucinated handle never binds to some result.
    public func get(chatID: String, id: String) -> DataRef? {
        lock.lock(); defer { lock.unlock() }
        guard let m = refs[chatID], !m.isEmpty else { return nil }
        if let r = m[id] { return r }
        return Self.nearest(id, in: Array(m.keys)).flatMap { m[$0] }
    }

    static func nearest(_ typed: String, in ids: [String]) -> String? {
        var t = typed.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`"))).lowercased()
        if !t.hasPrefix("qr_") { t = "qr_" + t }
        if ids.contains(t) { return t }
        if t.count >= 3 + 8 {
            let p = ids.filter { $0.hasPrefix(t) }
            if p.count == 1 { return p[0] }
            if p.count > 1 { return nil }
        }
        let d = ids.map { ($0, editDistance(t, $0, limit: 6)) }.sorted { $0.1 < $1.1 }
        guard let best = d.first, best.1 <= 2 else { return nil }
        if d.count > 1, d[1].1 - best.1 < 3 { return nil }
        return best.0
    }

    /// Levenshtein distance, capped at `limit` (returns `limit` once every path exceeds it).
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        if abs(a.count - b.count) >= limit { return limit }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            cur[0] = i
            var rowMin = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                rowMin = min(rowMin, cur[j])
            }
            if rowMin >= limit { return limit }
            swap(&prev, &cur)
        }
        return min(prev[b.count], limit)
    }

    /// Every result of a chat, oldest first (M6.T10: a sheet retyping one of them must pass its data_ref; M6.T12: a
    /// chart without data_ref binds to the newest result that has its fields).
    public func all(chatID: String) -> [DataRef] {
        lock.lock(); defer { lock.unlock() }
        let m = refs[chatID] ?? [:]
        return (order[chatID] ?? []).compactMap { m[$0] }
    }

    /// A result by id in any chat (ids are UUIDs; the ChartCard's spec-error state shows its rows).
    public func find(id: String) -> DataRef? {
        lock.lock(); defer { lock.unlock() }
        return refs.values.lazy.compactMap { $0[id] }.first
    }

    public func drop(chatID: String) {
        lock.lock(); defer { lock.unlock() }
        refs[chatID] = nil
        order[chatID] = nil
    }

    public static func newID() -> String { "qr_" + UUID().uuidString.lowercased() }
}
