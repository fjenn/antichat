// M7.T03 follow-up (AT-250 c2, R-250 AC2, A-M7-T03c option c): the helper's citation entailment check. MiniCheck
// (Tang et al. 2024, lytang/MiniCheck-RoBERTa-Large, MIT) as published in Core ML by simst (fp16, input 1 × 512,
// output `support_prob`) — a fact-checking cross-encoder: P(the document supports the claim). Core ML with
// `.cpuAndNeuralEngine`: it never takes the GPU from the chat model. Catalog role `cite_check` (on demand, key prefix
// `cite`); the app sends it as a `RerankRequest` (query = the cited sentence, documents = the cited sources' text).
// A document longer than one window is cut into overlapping windows (MiniCheck's chunking) and scored by its best
// window; all windows of a request run as one Core ML batch. Residency: the scheduler's `rerank` role (2 min idle).
import AntiChatEngineProtocol
import AntiChatFoundation
@preconcurrency import CoreML
import Foundation
import Tokenizers

public actor CiteCheckService {
    public static let window = 512
    /// Successive windows overlap by a quarter (stride = 3/4 of the room left after the claim).
    static let strideFraction = 0.75
    /// Windows per Core ML batch call.
    public static let batchSize = 64
    /// Windows scored per (claim, premise) pair: the ones sharing the most claim tokens (a long page is cut into many
    /// windows; scoring all of an 8-source sentence missed the turn's time bound on T1). Chosen on the labelled set.
    public static let windowsPerPair = 2
    /// Windows per request: above it every pair gets its single best window (one 64-window batch ≈ 2–4 s on T1).
    public static let windowBudget = 64

    struct Loaded {
        let model: MLModel
        let tokenizer: any Tokenizer
    }

    private var loaded: [String: Loaded] = [:]

    public init() {}

    /// Catalog role `cite_check` (key `cite-check`, Core ML).
    public static func handles(_ slot: ModelSlot) -> Bool { slot.engine == .coreml && slot.key.hasPrefix("cite") }

    // MARK: Residency (EngineRuntime, for the scheduler only)

    public func load(_ slot: ModelSlot) async throws -> Double {
        if loaded[slot.key] != nil { return 0 }
        let dir = URL(fileURLWithPath: slot.path, isDirectory: true)
        let start = ContinuousClock.now
        let compiled = try Self.compiledModel(in: dir, key: slot.key)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        do {
            let model = try MLModel(contentsOf: compiled, configuration: config)
            let tokenizer = try await AutoTokenizer.from(modelFolder: dir)
            loaded[slot.key] = Loaded(model: model, tokenizer: tokenizer)
        } catch {
            throw AntiChatError(.modelCorrupt, detail: "\(slot.key): \(error)")
        }
        return EngineTime.secs(ContinuousClock.now - start)
    }

    public func unload(_ key: String) { loaded[key] = nil }
    public func holds(_ key: String) -> Bool { loaded[key] != nil }

    /// The `.mlmodelc` to load: one shipped in the install, else the `.mlpackage` compiled once into the helper's
    /// caches (keyed by the package's weight file size + mtime, so a re-install recompiles).
    static func compiledModel(in dir: URL, key: String) throws -> URL {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if let c = names.first(where: { $0.hasSuffix(".mlmodelc") }) { return dir.appending(path: c) }
        guard let p = names.first(where: { $0.hasSuffix(".mlpackage") }) else { throw AntiChatError(.modelMissing, detail: key) }
        let pkg = dir.appending(path: p).resolvingSymlinksInPath()
        let weights = pkg.appending(path: "Data/com.apple.CoreML/weights/weight.bin").resolvingSymlinksInPath()
        let attrs = try? fm.attributesOfItem(atPath: weights.path)
        let stamp = "\((attrs?[.size] as? Int) ?? 0)-\(Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))"
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "AntiChat/coreml/\(key)-\(stamp)")
        let target = caches.appending(path: p.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"))
        if fm.fileExists(atPath: target.appending(path: "coremldata.bin").path) { return target }
        // Core ML's compiler cannot follow a package whose files are symlinks (the content-addressed install view):
        // compile a resolved copy.
        let staging = caches.appending(path: "staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appending(path: p)
        try copyResolving(pkg, to: copy)
        let out = try MLModel.compileModel(at: copy)
        try? fm.removeItem(at: target)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.moveItem(at: out, to: target)
        return target
    }

    static func copyResolving(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appending(path: name).resolvingSymlinksInPath(), d = dst.appending(path: name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            if isDir.boolValue { try copyResolving(s, to: d) } else { try fm.copyItem(at: s, to: d) }
        }
    }

    // MARK: Work

    /// Separator of a (claim, premise) pair inside one `RerankRequest` document when the query is empty: the app sends
    /// every pair of an answer in one request, so all windows run as one batch.
    public static let pairSeparator: Character = "\u{1F}"

    /// The pairs of a request: query = claim for every document, or (empty query) `claim␟premise` documents.
    public static func pairs(query: String, documents: [String]) -> [(claim: String, premise: String)] {
        if !query.isEmpty { return documents.map { (query, $0) } }
        return documents.map { d in
            guard let i = d.firstIndex(of: pairSeparator) else { return ("", d) }
            return (String(d[..<i]), String(d[d.index(after: i)...]))
        }
    }

    /// P(supported) of each pair's claim by its premise (best window), in order.
    public func score(pairs: [(claim: String, premise: String)], key: String,
                      windowsPerPair: Int = CiteCheckService.windowsPerPair) async throws -> [Float] {
        guard let m = loaded[key] else { throw AntiChatError(.modelMissing, detail: key) }
        var inputs: [[Int]] = [], owner: [Int] = []
        var claimCache: [String: [Int]] = [:]
        let perPair = pairs.count * windowsPerPair > Self.windowBudget ? 1 : windowsPerPair
        for (d, pair) in pairs.enumerated() {
            let claimIDs = claimCache[pair.claim] ?? Array(m.tokenizer.encode(text: pair.claim, addSpecialTokens: false).prefix(Self.window / 4))
            claimCache[pair.claim] = claimIDs
            guard !claimIDs.isEmpty else { continue }
            let all = Self.windows(document: m.tokenizer.encode(text: pair.premise, addSpecialTokens: false), claimCount: claimIDs.count)
            for w in Self.best(all, claim: claimIDs, keep: perPair) {
                // RoBERTa pair: <s> doc </s></s> claim </s>
                inputs.append([0] + w + [2, 2] + claimIDs + [2])
                owner.append(d)
            }
        }
        var scores = [Float](repeating: 0, count: pairs.count)
        guard !inputs.isEmpty else { return scores }
        for b in stride(from: 0, to: inputs.count, by: Self.batchSize) {
            let part = inputs[b..<min(b + Self.batchSize, inputs.count)]
            let batch = try MLArrayBatchProvider(array: part.map { try Self.features($0) })
            let out = try await m.model.predictions(from: batch, options: MLPredictionOptions())
            for i in 0..<out.count {
                guard let p = out.features(at: i).featureValue(for: "support_prob")?.multiArrayValue, p.count > 0 else { continue }
                scores[owner[b + i]] = max(scores[owner[b + i]], p[p.count - 1].floatValue)
            }
        }
        return scores
    }

    /// The `keep` windows with the most distinct claim tokens (ties: earlier first); all when `keep` ≤ 0.
    static func best(_ windows: [[Int]], claim: [Int], keep: Int) -> [[Int]] {
        guard keep > 0, windows.count > keep else { return windows }
        let c = Set(claim)
        let ranked = windows.enumerated().map { (i, w) in (i, c.intersection(w).count) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return ranked.prefix(keep).map(\.0).sorted().map { windows[$0] }
    }

    /// Overlapping windows of a document's tokens that fit beside a claim of `claimCount` tokens.
    static func windows(document: [Int], claimCount: Int) -> [[Int]] {
        let room = max(16, window - claimCount - 4)
        guard document.count > room else { return [document] }
        let stride = max(1, Int(Double(room) * strideFraction))
        var out: [[Int]] = [], i = 0
        while true {
            out.append(Array(document[i..<min(i + room, document.count)]))
            if i + room >= document.count { break }
            i += stride
        }
        return out
    }

    static func features(_ ids: [Int]) throws -> MLDictionaryFeatureProvider {
        let shape: [NSNumber] = [1, NSNumber(value: window)]
        let input = try MLMultiArray(shape: shape, dataType: .int32), mask = try MLMultiArray(shape: shape, dataType: .int32)
        let n = min(ids.count, window)
        for j in 0..<window {
            input[j] = NSNumber(value: j < n ? Int32(ids[j]) : 1)  // <pad> = 1
            mask[j] = NSNumber(value: j < n ? 1 : 0)
        }
        return try MLDictionaryFeatureProvider(dictionary: ["input_ids": input, "attention_mask": mask])
    }
}
