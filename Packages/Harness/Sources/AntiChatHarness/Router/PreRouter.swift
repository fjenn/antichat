// M2.T22 (R-235 AC1/AC2; G-013; P-shell-13): the semantic pre-router. Before the TurnController builds a request it
//   1. lets a tool chip force its tool (ChipOverride, every turn while the chip is present);
//   2. short-circuits pure conversation with the vendored Osaurus `CapabilityQueryIntent` gate (no embed call);
//   3. scores the seven intents (RouteScorer: one embed request, cosine top-k mean, rules layer);
//   4. prunes the exposed tools to ≤ 4 on T0–T2 (ToolPruner).
// Scores never block a request (R-241): the worst a wrong score does is expose a different tool set; the request
// always goes out. `FeatureFlag.preRouter` off → no scoring, every tool exposed; chips still force.
// Budget (R-235 AC2): ≤ 30 ms p95 on S1 (`make bench FILTER=RouterBench`, `bench.router.S1scaled.p95`).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import OsaurusVendored

public struct PreRouter: Sendable {
    public let scorer: RouteScorer?
    public let thresholds: [Route: RouteThreshold]
    public let decisiveGap: Float
    public let enabled: @Sendable () -> Bool
    /// M2.T23b (R-235 AC2: ≤ 30 ms on S1): the most a send waits for the embed. 10 ms: at 20 ms the cold path measured
    /// p95 29.6 / max 31.8 ms on a quiet host (timer + actor hops); at 10 ms p95 15.1 ms. The cost: a cold send whose
    /// XPC embed (quiet p50 17 ms) would have landed in 10–20 ms goes out unscored. The composer prefetches the vector
    /// while the user types (`RoutePrefetch`), so a send normally finds it cached and only scores on the CPU; if the
    /// embed is not back in time the turn goes out unscored (no forced tool, the default tool set) — never later.
    public var sendBudget: Duration? = .milliseconds(10)

    public init(scorer: RouteScorer?, thresholds: [Route: RouteThreshold]? = nil,
                enabled: @escaping @Sendable () -> Bool = { FeatureFlag.preRouter.isEnabled() }) {
        self.scorer = scorer
        self.thresholds = thresholds ?? scorer?.prototypes.thresholds ?? [:]
        decisiveGap = thresholds == nil ? (scorer?.prototypes.file.decisiveGap ?? 0) : 0
        self.enabled = enabled
    }

    /// The app's router over `embedding` with the bundled prototypes (nil when the resource is missing).
    public static func bundled(embedding: any RouteEmbedding) -> PreRouter? {
        guard let p = RoutePrototypes.bundled else { return nil }
        return PreRouter(scorer: RouteScorer(prototypes: p, embedding: embedding))
    }

    /// The decision for one turn. `tools` = what the turn may offer (already filtered for the model).
    public func decide(userText: String?, hasImage: Bool, chips: [String], tools: [ToolSchema], tier: DeviceTier) async
        -> RouteDecision
    {
        let signpost = Signposts.begin(.routerDecision, on: Signposts.harness)
        var d = RouteDecision()
        defer {
            Signposts.end(.routerDecision, signpost, on: Signposts.harness, meta: [
                "top": d.top?.rawValue ?? "chat", "confident": "\(d.confident)", "confirmed": "\(d.mediaConfirmed)",
                "forced": d.forcedTool ?? "",
                "exposed": "\(d.toolsToExpose.count)", "skipped": d.skipped?.rawValue ?? "",
            ])
        }
        let sorted = tools.sorted { $0.name < $1.name }
        d.forcedTool = ChipOverride.forcedTool(chips: chips, offered: sorted)
        guard enabled() else {
            d.skipped = .disabled
            d.toolsToExpose = sorted
            return d
        }
        let text = userText ?? ""
        if CapabilityQueryIntent.isConversationalAbstain(text) {
            d.skipped = .conversational
        } else if let scorer {
            if !(await scorer.isReady) {
                // Not prepared yet (first launch embeds the prototypes once, then the disk cache): build it in the
                // background and send this turn unscored; a turn never waits for it.
                Task.detached(priority: .utility) { await scorer.prepare() }
                d.skipped = .notReady
            } else {
                switch await scorer.score(text, hasImage: hasImage, within: sendBudget) {
                case .scores(let s):
                    d.scores = s
                    // The request's own words pick picture vs video once the scores say "media" (MediumCue).
                    let cue = MediumCue.medium(text, hasImage: hasImage)
                    (d.top, d.confident) = Self.top(s, thresholds: thresholds, decisiveGap: decisiveGap, mediumNamed: cue != nil)
                    d.top = MediumCue.resolve(d.top, text: text, hasImage: hasImage)
                    // A media route the words do not back exposes its tool but never cards or forces (MediumCue).
                    if let top = d.top, top.isMedia {
                        d.mediaConfirmed = MediumCue.confirmsMedia(text, hasImage: hasImage, top: top)
                    }
                case .timedOut: d.skipped = .timedOut
                case .failed: d.skipped = .failed
                }
            }
        } else {
            d.skipped = .noEmbedder
        }
        // R66 F2: a turn that went out unscored (the embed missed the send budget — a cold embed model, a paste-and-send
        // before the composer prefetch, a busy helper — or no scorer at all) used to get the default tool set, so
        // "Draw me a lighthouse at dusk" was never offered create_image and silently answered in text. The request's own
        // words still name the medium: route on them. Exposure only — not confident, so no forced call and no card.
        if let skipped = d.skipped, Self.unscored.contains(skipped), let r = MediumCue.unscoredRoute(text, hasImage: hasImage) {
            d.top = r
            d.confident = false
            d.mediaConfirmed = true
        }
        d.routedTools = ToolPruner.routedTools(scores: d.scores, thresholds: thresholds, top: d.top)
        d.toolsToExpose = ToolPruner.prune(sorted, scores: d.scores, thresholds: thresholds, forced: d.forcedTool, top: d.top,
                                           tier: tier)
        return d
    }

    /// The skips after which the words alone may route a media turn (not `disabled` / `conversational`).
    static let unscored: Set<RouteDecision.Skipped> = [.timedOut, .notReady, .failed, .noEmbedder]

    /// The intent whose margin over the `chat` score exceeds its `low` threshold by the most (M2.T23 fit: margins over
    /// chat separate far better than raw cosines); confident when the margin also reaches `high` and the excess beats
    /// the best intent that exposes another tool by `decisiveGap`.
    /// `mediumNamed`: the request's words name picture or video (MediumCue), which then picks between the two media
    /// tools, so a near-tie between an image and a video route no longer makes a media turn unsure — only non-media
    /// rivals count against it (M4 AT-030 run: "Animeer deze foto…", "clip animado de…" scored image ≈ video and went
    /// out unsure, so the model's silence was never re-asked; video recall 0.79 vs 1.0 at M2).
    public static func top(_ s: [Route: Float], thresholds: [Route: RouteThreshold], decisiveGap: Float = 0,
                           mediumNamed: Bool = false) -> (Route?, Bool) {
        let chat = s[.chat] ?? 0
        func excess(_ r: Route) -> Float? {
            guard let v = s[r], let t = thresholds[r] else { return nil }
            return v - chat - t.low
        }
        var best: (Route, Float)?
        for r in Route.intents {
            guard let gap = excess(r) else { continue }
            if gap >= 0, best == nil || gap > best!.1 { best = (r, gap) }
        }
        guard let (r, gap) = best else { return (nil, false) }
        let rival = Route.intents.filter { $0.tools != r.tools && !(mediumNamed && r.isMedia && $0.isMedia) }
            .compactMap(excess).max() ?? -.infinity
        return (r, (s[r] ?? 0) - chat >= (thresholds[r]?.high ?? .infinity) && gap - rival >= decisiveGap)
    }
}
