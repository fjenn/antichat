// M2.T22 step 2 (R-235 AC2; P-shell-13): scores one user message against the route prototypes.
// Ported from aurelio-labs/semantic-router@aef8310 `routers/base.py` (`_score_routes`: top-k utterance matches grouped
// by route, `aggregation="mean"`) and `index/local.py` (cosine = dot of unit vectors over one matrix); MIT. The
// `EmbeddingProvider` seam follows jaumesaa/ActionRouter@7d94cb6. One embed request per send (the message only,
// batched with nothing else); the dot products run on the CPU through Accelerate.
// Rules layer: an attached image raises the attachment routes (image_edit, video_from_image) and its absence lowers
// them. Cues only SCORE; nothing here blocks or rewrites a request (R-241).
import Accelerate
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

/// The embed model the router uses (live: the helper's `embed` slot over XPC; tests: a deterministic fake).
public protocol RouteEmbedding: Sendable {
    /// Identifies the model version (cache key); nil = no embed model installed → no scores.
    var modelID: String? { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public actor RouteScorer {
    public let prototypes: RoutePrototypes
    private let embedding: any RouteEmbedding
    private let cacheDirectory: URL?
    /// Row-major unit vectors (rows × dim) and the route of each row.
    private var matrix: [Float] = []
    private var dim = 0
    private var rowRoutes: [Route] = []
    private var preparedFor: String?
    private var preparing: Task<Bool, Never>?
    /// M2.T23b (R-235 AC2): message vectors embedded ahead of the send (composer debounce) and the embeds in flight,
    /// by normalised text. Small: only the last few drafts matter.
    private var vectors: [String: [Float]] = [:]
    private var vectorOrder: [String] = []
    private var inflight: [String: Task<[Float]?, Never>] = [:]
    /// Bumped on every prototype load (a new embed model): older embeds are not cached.
    private var generation = 0
    static let cachedTexts = 8
    /// The one-word embed that loads a cold embed model (R66 F2).
    static let warmText = "hello"

    public init(prototypes: RoutePrototypes, embedding: any RouteEmbedding,
                cacheDirectory: URL? = RoutePrototypes.defaultCacheDirectory) {
        self.prototypes = prototypes
        self.embedding = embedding
        self.cacheDirectory = cacheDirectory
    }

    public var isReady: Bool { preparedFor != nil && preparedFor == embedding.modelID }

    /// Embeds (or loads from the cache) every prototype for the current embed model. Idempotent; false when no
    /// embed model is installed or embedding failed.
    @discardableResult
    public func prepare() async -> Bool {
        if isReady { return true }
        if let p = preparing { return await p.value }
        let t = Task { await self.load() }
        preparing = t
        let ok = await t.value
        preparing = nil
        return ok
    }

    private func load() async -> Bool {
        guard let model = embedding.modelID else { return false }
        let url = cacheDirectory.map { prototypes.cacheURL(modelID: model, directory: $0) }
        var vectors = url.flatMap { prototypes.loadCache($0) }
        if vectors != nil {
            // R66 F2: prototypes from the disk cache make the router ready without one embed call, so the embed model
            // itself was still cold and the first message embed (model load) missed the send budget: the turn went out
            // unscored. Load the model now, off the send path, as a first launch's prototype embed does.
            let embedding = embedding
            Task(priority: .utility) { _ = try? await embedding.embed([Self.warmText]) }
        }
        if vectors == nil {
            let texts = prototypes.rows.map(\.text)
            var out: [[Float]] = []
            out.reserveCapacity(texts.count)
            do {
                for start in stride(from: 0, to: texts.count, by: 64) {
                    out += try await embedding.embed(Array(texts[start..<min(texts.count, start + 64)]))
                }
            } catch {
                AppLog.log(.harness, .error, "router prototypes embed failed: \(error)")
                return false
            }
            guard out.count == texts.count else { return false }
            vectors = out.map(Self.unit)
            if let url { prototypes.writeCache(vectors!, to: url) }
        }
        guard let v = vectors, let d = v.first?.count, d > 0, v.allSatisfy({ $0.count == d }) else { return false }
        // A new embed model (maybe another dimension): draft vectors of the old one must not be scored against the
        // new matrix (M2 review #15).
        self.vectors = [:]
        vectorOrder = []
        inflight = [:]
        generation += 1
        matrix = v.flatMap { $0 }
        dim = d
        rowRoutes = prototypes.rows.map(\.route)
        preparedFor = model
        return true
    }

    /// Scores for all eight routes (seven intents + chat); nil when the prototypes are not ready or the embed failed.
    public func score(_ text: String, hasImage: Bool) async -> [Route: Float]? {
        guard case .scores(let s) = await score(text, hasImage: hasImage, within: nil) else { return nil }
        return s
    }

    public enum Outcome: Sendable, Hashable {
        case scores([Route: Float])
        /// The embed did not finish within the send budget; it keeps running and fills the cache.
        case timedOut
        case failed
    }

    static func key(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// M2.T23b: embed `text` now, off the send path (the composer calls this while the user types; R-235 AC2). The
    /// vector is cached, so the send that follows only runs the CPU scoring.
    public func prefetch(_ text: String) {
        let k = Self.key(text)
        // Not prepared yet (e.g. the embed model arrived after launch): prepare in the background so the next send is
        // scored; this draft goes out as it would have.
        if !isReady, preparing == nil, embedding.modelID != nil { Task { await self.prepare() } }
        guard isReady, !k.isEmpty, vectors[k] == nil, inflight[k] == nil else { return }
        _ = vectorTask(k)
    }

    /// Whether `text`'s vector is cached (tests, diagnostics).
    public func isPrefetched(_ text: String) -> Bool { vectors[Self.key(text)] != nil }

    /// M7.T14: the message's unit vector when it was embedded already (the send's score or the composer prefetch);
    /// ToolIndex ranks tools with it, so selection costs no second embed.
    public func cachedVector(_ text: String) -> [Float]? { vectors[Self.key(text)] }

    /// M7.T14: the embed model the vectors come from (the tool index must use the same one).
    public nonisolated var embeddingModel: any RouteEmbedding { embedding }

    private func vectorTask(_ k: String) -> Task<[Float]?, Never> {
        if let t = inflight[k] { return t }
        let embedding = embedding, dim = dim
        let t = Task<[Float]?, Never> {
            guard let v = try? await embedding.embed([k]).first, v.count == dim else { return nil }
            return Self.unit(v)
        }
        inflight[k] = t
        let gen = generation
        Task { await self.store(k, await t.value, generation: gen) }
        return t
    }

    private func store(_ k: String, _ v: [Float]?, generation gen: Int) {
        // An embed of the previous model that lands after a reload is dropped (M2 review #15).
        guard gen == generation else { return }
        inflight[k] = nil
        guard let v else { return }
        vectors[k] = v
        vectorOrder.removeAll { $0 == k }
        vectorOrder.append(k)
        while vectorOrder.count > Self.cachedTexts { vectors[vectorOrder.removeFirst()] = nil }
    }

    /// Scores with a wait limit: a prefetched vector → CPU only; otherwise the embed (started now, or the one the
    /// composer started) is awaited at most `budget` (nil = no limit). A late embed is not lost: it fills the cache.
    public func score(_ text: String, hasImage: Bool, within budget: Duration?) async -> Outcome {
        guard isReady else { return .failed }
        let k = Self.key(text)
        if let v = vectors[k], v.count == dim { return .scores(scores(for: v, hasImage: hasImage)) }
        let t = vectorTask(k)
        let v: [Float]??
        if let budget {
            v = await Self.first(of: t, within: budget)
        } else {
            v = .some(await t.value)
        }
        switch v {
        case .none: return .timedOut
        case .some(.none): return .failed
        case .some(.some(let vec)): return .scores(scores(for: vec, hasImage: hasImage))
        }
    }

    /// Scores of an already-embedded message (bench / calibration dumps reuse one vector).
    public func scores(for unitVector: [Float], hasImage: Bool) -> [Route: Float] {
        // vDSP_mmul reads `dim` floats from the vector: a vector of another size reads past its end (M2 review #15).
        guard dim > 0, unitVector.count == dim else { return [:] }
        let n = rowRoutes.count
        var sims = [Float](repeating: 0, count: n)
        matrix.withUnsafeBufferPointer { m in
            unitVector.withUnsafeBufferPointer { q in
                sims.withUnsafeMutableBufferPointer { out in
                    // (n × dim) · (dim × 1) → n
                    vDSP_mmul(m.baseAddress!, 1, q.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(n), 1, vDSP_Length(dim))
                }
            }
        }
        var raw = Self.aggregate(sims: sims, routes: rowRoutes, k: prototypes.file.k)
        for r in [Route.imageEdit, .videoFromImage] where raw[r] != nil {
            raw[r]! += hasImage ? prototypes.file.attachmentBonus : -prototypes.file.noAttachmentPenalty
        }
        return raw
    }

    /// Mean of the k best similarities per route (semantic-router `_score_routes`, `aggregation="mean"`).
    nonisolated static func aggregate(sims: [Float], routes: [Route], k: Int) -> [Route: Float] {
        var by: [Route: [Float]] = [:]
        for (s, r) in zip(sims, routes) { by[r, default: []].append(s) }
        return by.mapValues { xs in
            let top = xs.sorted(by: >).prefix(max(1, k))
            return top.reduce(0, +) / Float(top.count)
        }
    }

    /// `t`'s value if it arrives within `budget`, else nil at the deadline (`t` keeps running; a task group would wait
    /// for it, since awaiting a Task's value does not react to cancellation).
    nonisolated static func first(of t: Task<[Float]?, Never>, within budget: Duration) async -> [Float]?? {
        final class Once: Sendable { let done = Mutex(false); func claim() -> Bool { done.withLock { let f = !$0; $0 = true; return f } } }
        let once = Once()
        return await withCheckedContinuation { (c: CheckedContinuation<[Float]??, Never>) in
            Task { let r = await t.value; if once.claim() { c.resume(returning: .some(r)) } }
            Task { try? await Task.sleep(for: budget); if once.claim() { c.resume(returning: .none) } }
        }
    }

    nonisolated static func unit(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        let n = norm.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}

/// The router's embedder before the engine exists (the composition root fills it once the environment is open).
public final class DeferredRouteEmbedding: RouteEmbedding {
    private let inner = Mutex<(any RouteEmbedding)?>(nil)
    public init() {}
    public func set(_ e: any RouteEmbedding) { inner.withLock { $0 = e } }
    /// The composition root filled it (the wiring test).
    public var isSet: Bool { inner.withLock { $0 } != nil }
    public var modelID: String? { inner.withLock { $0 }?.modelID }
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let e = inner.withLock({ $0 }) else { throw AntiChatError(.modelMissing, detail: "router embed") }
        return try await e.embed(texts)
    }
}

/// The helper's `embed` model (Qwen3-Embedding) as the router's embedder: symmetric, no query instruction.
extension HelperEmbedder: RouteEmbedding {
    public var modelID: String? { embedSlot().map { "\($0.key)@\($0.path)" } }
    public func embed(_ texts: [String]) async throws -> [[Float]] { try await embed(texts, kind: .document) }
}
