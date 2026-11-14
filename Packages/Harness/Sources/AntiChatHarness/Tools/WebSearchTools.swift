// M7.T03 step 3–4 (R-080 AC3, R-248 AC1): `web_search` and `read_url` in the tool registry. Read-only (they change
// nothing; their output is untrusted). Offered only while WebSearchAvailability says so (switch on, Offline only
// off, network up): the registry entry flips to `.unavailable` on every change, so offline no web tool is in the
// prompt (R-267) and the chat works as before. Query count, pages and evidence budget per tier (tier-budgets.json).
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatTools
import Foundation

public enum WebSearchTools {
    /// The web tools (chip forcing, the offline notice, `ttftSearch`).
    public static let names: Set<String> = ["web_search", "read_url"]
    /// M7 bars (T1 search latency): tiers where the Web search chip's forced call is written by the harness with the
    /// user's message instead of a model step (the 4–9B models spend ≈ 2.5 s prefilling and writing that call; the
    /// query they write is close to the message). T2 and T4 models still write their own queries.
    /// M9.T05 (AT-254 T3, first token p50 ≤ 5 s; A-M9-T05b): T3 too — its model step cost ≈ 1.2 s of the first token.
    /// With the evidence budget kept at 10000 (cutting it failed AT-250 c2): T05 queries p50 4.52 s (warm page cache),
    /// unfetched queries 6.10 s (closed by the T3 page-fetch deadline, search.fetch_deadline_s: 4.23 s p50 cold, c2 0.928,
    /// `build/at/AT-254/t3-deadline/`); c2 T3 held-out-5 0.927 (`build/at/AT-254/t05-fix/`, `AT-250/t05-h5-direct10k/`).
    public static let directSearchTiers: Set<String> = ["T0", "T1", "T3"]
    public static let webSearchParameters = #"{"type":"object","properties":{"queries":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3,"description":"1-3 standalone search queries (no personal data)"},"freshness":{"type":"string","enum":["day","week","month","any"]},"category":{"type":"string","enum":["general","news"]}},"required":["queries"]}"#
    public static let readURLParameters = #"{"type":"object","properties":{"url":{"type":"string","description":"An http(s) URL the user gave"}},"required":["url"]}"#

    struct ReadArgs: Decodable { var url: String }

    /// The shared embedding model (and the T2+ reranker) for page ranking (A-M7-T02a f); the composition root sets it
    /// once the helper exists (`useEmbedder`). Until then, and without an embed model, ranking is BM25 only.
    final class EmbedBox: @unchecked Sendable {
        static let shared = EmbedBox()
        private let lock = NSLock()
        private var embedder: (any Embedder)?
        func set(_ e: (any Embedder)?) { lock.withLock { embedder = e } }
        var current: (any Embedder)? { lock.withLock { embedder } }
    }

    public static func useEmbedder(_ e: (any Embedder)?) { EmbedBox.shared.set(e) }

    /// M9.T05 (AT-254 T3): the running turn's chat-model tokenizer (TurnController sets it around a web tool call:
    /// the turn's engine + model slot), so `search.evidence_tokens` is counted in that model's real tokens.
    @TaskLocal public static var tokenCounter: EvidenceBudget.BatchCount?
    /// The page-ranking embedder the composition root set (nil = BM25 only).
    public static var embedder: (any Embedder)? { EmbedBox.shared.current }

    /// The app's ranker: hybrid BM25 + the shared embedder (query prefix on the first text only), reranker on T2+.
    public static let appRanker = EvidenceRanker(
        embed: { texts in
            guard let e = EmbedBox.shared.current, let q = texts.first else { return nil }
            guard let qv = try? await e.embed([q], kind: .query), let dv = try? await e.embed(Array(texts.dropFirst()), kind: .document)
            else { return nil }
            return qv + dv
        },
        rerank: { query, docs in
            guard let e = EmbedBox.shared.current, let s = try? await e.rerank(query: query, documents: docs) else { return nil }
            return s.map(Double.init)
        })

    /// The turn's pipeline: an incognito chat (in-memory store) fetches through the incognito session with the
    /// in-memory page cache, so nothing of it reaches the disk or `network_activity` (cross-task rule 5).
    final class Pipelines: @unchecked Sendable {
        let normal: WebSearchPipeline
        private let lock = NSLock()
        private var incognitoPipeline: WebSearchPipeline?
        init(_ normal: WebSearchPipeline) { self.normal = normal }
        var current: WebSearchPipeline {
            guard ToolCallStore.database?.isInMemory == true else { return normal }
            return lock.withLock {
                if let p = incognitoPipeline { return p }
                let p = WebSearchPipeline(broker: SearchBroker(transport: SearchTransports.app(incognito: true), incognito: true),
                                          fetcher: PageFetcher(transport: GatedPageTransport(incognito: true), cache: MemoryWebCache()),
                                          ranker: normal.ranker, count: normal.count)
                incognitoPipeline = p
                return p
            }
        }
    }

    /// Reads the fetched pages' own icons after the step (never delays the tool result) into the turn's sources.
    static func loadFavicons(_ r: WebResults, pipeline: WebSearchPipeline, turn: String, sources: TurnWebSources) {
        guard !r.iconURLs.isEmpty else { return }
        let task = Task.detached {
            let icons = await pipeline.favicons(r.iconURLs)
            sources.setFavicons(icons, turn: turn)
        }
        sources.track(task, turn: turn)
    }

    /// The tier's search row from tier-budgets.json.
    public static func budget(tier: String, budgets: TierBudgets = .shared) -> (queries: Int, budget: WebSearchBudget) {
        let s = budgets.search
        return (TierBudgets.cell(s?.queries, tier) ?? 2,
                WebSearchBudget(pages: TierBudgets.cell(s?.pages, tier) ?? 4, evidenceTokens: TierBudgets.cell(s?.evidenceTokens, tier) ?? 3000,
                                raceBudget: TierBudgets.cell(s?.freeRaceBudgetS, tier) ?? 2.5, reranker: TierBudgets.cell(s?.reranker, tier) ?? false,
                                fetchDeadline: TierBudgets.cell(s?.fetchDeadlineS, tier)))
    }

    static func webSearch(pipeline: Pipelines, availability: WebSearchAvailability, tier: @escaping @Sendable () -> String,
                                 sources: TurnWebSources = .shared) -> RegisteredTool {
        RegisteredTool(name: "web_search", description: "Search the web for current information. Use when the answer needs facts newer than your training or the user asks to search.",
                       parametersJSON: webSearchParameters, sideEffect: .read,
                       availability: availability.isAvailable ? .available : .unavailable(reason: availability.state.rawValue),
                       outputIsUntrusted: true) { args in
            guard availability.isAvailable else { throw ToolRunError(availability.unavailableKey ?? "network.offlineForSearch") }
            let t = tier(), b = budget(tier: t)
            guard let plan = SearchPlan.make(arguments: args, maxQueries: b.queries) else {
                throw ToolRunError("web_search needs {\"queries\": [\"…\"]}.")
            }
            let p = pipeline.current, turn = TurnContext.requestID ?? "-"
            // review #11: the model's time filter (and category news) reaches the engines' date parameters.
            let r = await p.search(queries: plan.queries, budget: b.budget,
                                   freshness: SearchFreshness.effective(freshness: plan.freshness, category: plan.category),
                                   countBatch: tokenCounter)
            let numbered = sources.record(r, turn: turn)
            // K-search-blocking: blocked engines are never retried; only when none answered does the step fail.
            if r.failed != nil, r.evidence.isEmpty { throw ToolRunError("search.failed") }
            loadFavicons(numbered, pipeline: p, turn: turn, sources: sources)
            return WebResultsBlock.render(numbered, atomic: WebResultsBlock.atomicTiers.contains(t))
        }
    }

    static func readURL(pipeline: Pipelines, availability: WebSearchAvailability, tier: @escaping @Sendable () -> String,
                               sources: TurnWebSources = .shared) -> RegisteredTool {
        RegisteredTool(name: "read_url", description: "Read the page at a URL the user gave and answer from it.",
                       parametersJSON: readURLParameters, sideEffect: .read,
                       availability: availability.isAvailable ? .available : .unavailable(reason: availability.state.rawValue),
                       outputIsUntrusted: true) { args in
            guard availability.isAvailable else { throw ToolRunError(availability.unavailableKey ?? "network.offlineForSearch") }
            guard let a = try? JSONDecoder().decode(ReadArgs.self, from: Data(args.utf8)), let u = URL(string: a.url),
                  ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { throw ToolRunError("read_url needs {\"url\": \"https://…\"}.") }
            let p = pipeline.current, turn = TurnContext.requestID ?? "-"
            let t = tier()
            let r = await p.read(url: u, budget: budget(tier: t).budget, countBatch: tokenCounter)
            let numbered = sources.record(r, turn: turn)
            if r.failed != nil { throw ToolRunError("Couldn't read that page.") }
            loadFavicons(numbered, pipeline: p, turn: turn, sources: sources)
            return WebResultsBlock.render(numbered, atomic: WebResultsBlock.atomicTiers.contains(t))
        }
    }

    /// Registers both tools and keeps their availability in step with the switch / Offline only / path.
    public static func install(into registry: ToolRegistry, pipeline: WebSearchPipeline = WebSearchPipeline(ranker: appRanker),
                               availability: WebSearchAvailability = WebSearchAvailability(),
                               tier: @escaping @Sendable () -> String) -> [NSObjectProtocol] {
        let pipelines = Pipelines(pipeline)
        let refresh: @Sendable () -> Void = {
            registry.register(webSearch(pipeline: pipelines, availability: availability, tier: tier))
            registry.register(readURL(pipeline: pipelines, availability: availability, tier: tier))
        }
        refresh()
        return WebSearchAvailability.observe(refresh)
    }
}
