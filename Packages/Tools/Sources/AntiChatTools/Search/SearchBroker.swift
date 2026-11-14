// M7.T01 step 5 (R-248 AC2/AC3; blueprint B §B1.2 step 3): keyless metasearch in the app process. Per query the
// enabled HTML engines race in parallel under the tier's `free_race_budget_s` (2.5 s); results merge round-robin by
// rank, dedupe by normalized URL and keep their `engine`. Fallback chain on error, timeout or zero results: the other
// engines (the race itself) → the declarative engines (Wikipedia) → `.failed(reason)`. BYO and hosted providers
// (M7.T04) moved to M11 (D-026), so the chain ends here. Only the query words leave the Mac.
import Foundation
import OsaurusVendored

public struct SearchBudget: Sendable, Equatable {
    /// Wall-clock budget for one engine race (seconds).
    public var raceBudget: Double
    /// Hits read from each engine per query.
    public var perEngine: Int
    public init(raceBudget: Double = 2.5, perEngine: Int = 10) { self.raceBudget = raceBudget; self.perEngine = perEngine }
}

public struct SearchResultSet: Sendable {
    public enum Outcome: Sendable, Equatable { case ok, failed(reason: String) }
    public var outcome: Outcome
    public var hits: [SearchHit]
    /// One entry per engine call (engine id, ok, count, failure kind): the activity line's expandable detail.
    public var attempts: [SearchAttempt]
    public var elapsed: TimeInterval
    /// The coarse region hint the engine requests carried (SearchRegion), nil = none.
    public var region: String? = nil
    public var isFailed: Bool { if case .failed = outcome { return true }; return false }
    /// Engines that produced at least one kept hit.
    public var engines: [String] { Array(Set(hits.map(\.engine))).sorted() }
}

public struct SearchBroker: Sendable {
    public let registry: EngineRegistry
    public let transport: any SearchTransport
    public let safeSearch: @Sendable () -> Bool
    /// The coarse region hint (SearchRegion; "Use my approximate location for search"); never in an incognito chat.
    public let region: @Sendable () -> String?

    public init(registry: EngineRegistry = .shared, transport: any SearchTransport = SearchTransports.app(),
                safeSearch: @escaping @Sendable () -> Bool = { SafeSearch.isOn() }, incognito: Bool = false,
                region: (@Sendable () -> String?)? = nil) {
        self.registry = registry; self.transport = transport; self.safeSearch = safeSearch
        let none: @Sendable () -> String? = { nil }
        let live: @Sendable () -> String? = { SearchRegion.current(incognito: false) }
        self.region = incognito ? none : (region ?? live)
    }

    public func search(queries: [String], budget: SearchBudget = SearchBudget(), freshness: String? = nil) async -> SearchResultSet {
        let started = Date()
        let qs = queries.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !qs.isEmpty else { return SearchResultSet(outcome: .failed(reason: "no query"), hits: [], attempts: [], elapsed: 0) }
        let engines = registry.enabledEngines
        let html = engines.filter { $0.config.kind == .html }
        let fallback = engines.filter { $0.config.kind == .declarative }
        let safe = safeSearch()
        let region = region()

        var perQuery = await withTaskGroup(of: (Int, [[SearchHit]], [SearchAttempt]).self) { group in
            for (i, q) in qs.enumerated() {
                group.addTask { let r = await race(html, query: q, safe: safe, budget: budget, region: region, freshness: freshness); return (i, r.0, r.1) }
            }
            var out = [(lists: [[SearchHit]], attempts: [SearchAttempt])](repeating: ([], []), count: qs.count)
            for await (i, lists, attempts) in group { out[i] = (lists, attempts) }
            return out
        }
        // Fallback tier, per query that the race left empty.
        for (i, q) in qs.enumerated() where perQuery[i].lists.allSatisfy(\.isEmpty) {
            for engine in fallback {
                let (hits, attempt) = await call(engine, query: q, safe: safe, budget: budget, region: region, freshness: freshness)
                perQuery[i].attempts.append(attempt)
                if !hits.isEmpty { perQuery[i].lists.append(hits); break }
            }
        }
        let attempts = perQuery.flatMap(\.attempts)
        let hits = Self.merge(perQuery.flatMap(\.lists))
        let elapsed = Date().timeIntervalSince(started)
        guard !hits.isEmpty else {
            let kinds = Set(attempts.map(\.kind.rawValue)).sorted().joined(separator: ",")
            return SearchResultSet(outcome: .failed(reason: kinds.isEmpty ? "no engine enabled" : kinds), hits: [],
                                   attempts: attempts, elapsed: elapsed, region: region)
        }
        return SearchResultSet(outcome: .ok, hits: hits, attempts: attempts, elapsed: elapsed, region: region)
    }

    /// All engines in parallel; the race ends when every engine answered or the budget ran out (late engines are
    /// cancelled and recorded as `timeout`).
    func race(_ engines: [WebSearchEngine], query: String, safe: Bool, budget: SearchBudget, region: String? = nil,
              freshness: String? = nil) async -> ([[SearchHit]], [SearchAttempt]) {
        guard !engines.isEmpty else { return ([], []) }
        enum Event: Sendable { case done(Int, [SearchHit], SearchAttempt), deadline }
        return await withTaskGroup(of: Event.self) { group in
            for (i, e) in engines.enumerated() {
                group.addTask { let (h, a) = await call(e, query: query, safe: safe, budget: budget, region: region, freshness: freshness); return .done(i, h, a) }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(Int(budget.raceBudget * 1000)))
                return .deadline
            }
            var lists = [[SearchHit]](repeating: [], count: engines.count)
            var attempts = [SearchAttempt?](repeating: nil, count: engines.count)
            var pending = engines.count
            for await ev in group {
                switch ev {
                case .done(let i, let h, let a):
                    lists[i] = h; attempts[i] = a; pending -= 1
                case .deadline:
                    pending = 0
                }
                if pending == 0 { group.cancelAll(); break }
            }
            let recorded = attempts.enumerated().map { i, a in
                a ?? SearchAttempt(provider: engines[i].id, ok: false, kind: .timeout, error: "race budget \(budget.raceBudget)s")
            }
            return (lists, recorded)
        }
    }

    func call(_ engine: WebSearchEngine, query: String, safe: Bool, budget: SearchBudget, region: String? = nil,
              freshness: String? = nil) async -> ([SearchHit], SearchAttempt) {
        guard let request = engine.request(query: query, safeSearch: safe, timeout: max(budget.raceBudget, 1), region: region,
                                            freshness: freshness) else {
            return ([], SearchAttempt(provider: engine.id, ok: false, kind: .network, error: "bad URL template"))
        }
        do {
            let (status, data) = try await transport.send(request, engine: engine.id, query: query)
            try Task.checkCancellation()
            let hits = try engine.parse(status: status, data: data, max: budget.perEngine)
            return (hits, SearchAttempt(provider: engine.id, ok: true, count: hits.count))
        } catch let e as SearchBackendError {
            return ([], SearchAttempt(provider: engine.id, ok: false, kind: e.kind, error: e.message))
        } catch is CancellationError {
            return ([], SearchAttempt(provider: engine.id, ok: false, kind: .timeout, error: "cancelled at the race budget"))
        } catch {
            let kind: SearchFailureKind = (error as? URLError)?.code == .timedOut ? .timeout : .network
            return ([], SearchAttempt(provider: engine.id, ok: false, kind: kind, error: "\(error.localizedDescription)"))
        }
    }

    /// Round-robin by rank across result lists; the first occurrence of a normalized URL wins (its engine is kept).
    static func merge(_ lists: [[SearchHit]]) -> [SearchHit] {
        var seen = Set<String>(), out: [SearchHit] = []
        let depth = lists.map(\.count).max() ?? 0
        for r in 0..<depth {
            for l in lists where r < l.count {
                let key = normalize(l[r].url)
                if key.isEmpty || !seen.insert(key).inserted { continue }
                out.append(l[r])
            }
        }
        return out
    }

    /// Dedupe key: scheme dropped, host lowercased without `www.`, no fragment, no `utm_*` parameters, no trailing `/`.
    static func normalize(_ raw: String) -> String {
        guard var c = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)), let host = c.host?.lowercased() else {
            return raw.lowercased()
        }
        c.fragment = nil
        let items = (c.queryItems ?? []).filter { !$0.name.lowercased().hasPrefix("utm_") }
        c.queryItems = items.isEmpty ? nil : items
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return h + path + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}
