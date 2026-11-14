// ProvenanceRecorder (M1.T25 step 1, R-234 AC1; P-shell-03 per-message provenance after open-webui `chat_message`).
// Watches one turn's request and engine events and produces what `MessageRepository.finish` stores for the
// assistant message: `message.model_id` + `message.engine` (columns, written when the pending row is created) and
// `message.provenance_json`. Every assistant row gets a record, including interrupted and failed turns.
//
// provenance_json schema (keys as stored; MessageProvenance's CodingKeys):
//   model_sha        sha256 hex of the model's manifest (ModelManifestSHA): the dev store's `.hf-fetch.json`
//                    (repo + pinned commit + every file's git/LFS oid, canonical JSON); M2's signed catalog manifest
//                    replaces it. Scripted models: sha256 of the script. No manifest: sha256 of the file listing.
//   mode             normal | evil (the chat's mode)
//   sampling_json    {temperature, top_p, top_k, max_tokens, seed?, reasoning (0|1), reasoning_budget?}
//   tok_per_s        decode rate of this turn (partial turns: of the partial) — `usage.tokPerSec`
//   tok_per_s_source engine (from the turn's usage event) | app-estimate (no usage: ≈ chars/4 over the stream time)
//   ttft_ms          engine-side request → first content token (usage.ttftMs), else app-side send → first delta
//   prompt_hash      sha256 hex of the canonical prompt (messages with role/content/images/tool ids, tool schemas,
//                    tool choice, reasoning options): equal prompts → equal hash, any prompt change → new hash
//   reasoning_ms     M1.T15: first reasoning token → first answer token (or the last reasoning token); null without
//                    reasoning ("Thought for N s")
//   search_sources, memory_reads, skill: filled by M7/M8 (null in M1)
// The export (`TreeExport`, `antichat.tree.v1`) carries MessageProvenance as is.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import CryptoKit
import Foundation
import Synchronization

public struct ProvenanceRecorder: Sendable {
    public let mode: ChatMode
    public let sampling: Sampling
    public let reasoning: ReasoningOptions
    public let modelSHA: String?
    public let promptHash: String
    public let sentAt: ContinuousClock.Instant
    public private(set) var usage: Usage?
    public private(set) var firstDeltaAt: ContinuousClock.Instant?
    public private(set) var lastDeltaAt: ContinuousClock.Instant?
    public private(set) var deltaChars = 0
    /// M1.T15: the reasoning span (first reasoning delta → first answer delta after it, else the last reasoning delta).
    public private(set) var reasoningStartAt: ContinuousClock.Instant?
    public private(set) var reasoningEndAt: ContinuousClock.Instant?
    private var answerStarted = false

    public init(request: ChatRequest, mode: ChatMode, modelSHA: String? = nil, sentAt: ContinuousClock.Instant = .now) {
        self.mode = mode
        sampling = request.sampling
        reasoning = request.reasoning
        self.modelSHA = modelSHA ?? ModelManifestSHA.sha(for: request.modelSlot)
        promptHash = Self.promptHash(request)
        self.sentAt = sentAt
    }

    public mutating func observe(_ event: EngineEvent, at now: ContinuousClock.Instant = .now) {
        switch event {
        case .reasoningDelta:
            if reasoningStartAt == nil { reasoningStartAt = now }
            if !answerStarted { reasoningEndAt = now }
        case .textDelta, .toolCallDelta:
            if reasoningStartAt != nil, !answerStarted { reasoningEndAt = now }
            answerStarted = true
        default:
            break
        }
        switch event {
        case .textDelta(let s), .reasoningDelta(let s):
            if firstDeltaAt == nil { firstDeltaAt = now }
            lastDeltaAt = now
            deltaChars += s.count
        case .toolCallDelta(_, _, let f):
            if firstDeltaAt == nil { firstDeltaAt = now }
            lastDeltaAt = now
            deltaChars += f.count
        case .usage(let u):
            usage = u
        default:
            break
        }
    }

    /// The reasoning duration in ms (nil: no reasoning).
    public var reasoningMs: Double? {
        guard let a = reasoningStartAt, let b = reasoningEndAt else { return nil }
        return Self.secs(b - a) * 1000
    }

    public var samplingDict: [String: Double] {
        var d: [String: Double] = [
            // Float → its shortest decimal (0.7, not 0.699999988) so the stored value reads as the user set it.
            "temperature": Self.decimal(sampling.temperature), "top_p": Self.decimal(sampling.topP), "top_k": Double(sampling.topK),
            "max_tokens": Double(sampling.maxTokens), "reasoning": reasoning.on ? 1 : 0,
        ]
        if let s = sampling.seed { d["seed"] = Double(s) }
        if let b = reasoning.budget { d["reasoning_budget"] = Double(b) }
        return d
    }

    public func provenance() -> MessageProvenance {
        var tps: Double?
        var source: String?
        if let u = usage, u.tokPerSec > 0 || u.completionTokens == 0 {
            tps = u.tokPerSec
            source = "engine"
        } else if let a = firstDeltaAt, let b = lastDeltaAt {
            let secs = Self.secs(b - a)
            tps = secs > 0 ? Double(deltaChars) / 4 / secs : 0
            source = "app-estimate"
        } else {
            tps = 0  // nothing was generated: rate 0 rather than unknown
            source = usage == nil ? "app-estimate" : "engine"
        }
        let ttft = usage.map(\.ttftMs).flatMap { $0 > 0 ? $0 : nil } ?? firstDeltaAt.map { Self.secs($0 - sentAt) * 1000 }
        return MessageProvenance(
            modelSHA: modelSHA, mode: mode, sampling: samplingDict, tokPerS: tps, ttftMs: ttft, promptHash: promptHash,
            tokPerSSource: source, reasoningMs: reasoningMs)
    }

    /// sha256 of the canonical prompt (sorted-key JSON).
    public static func promptHash(_ r: ChatRequest) -> String {
        let msgs: [[String: Any]] = r.flattenedMessages.map { m in
            var d: [String: Any] = ["role": m.role.rawValue, "content": m.content]
            if !m.imagePaths.isEmpty { d["images"] = m.imagePaths }
            if let t = m.toolCallID { d["tool_call_id"] = t }
            return d
        }
        var obj: [String: Any] = [
            "messages": msgs, "tools": r.tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.parametersJSON] },
            "reasoning": ["on": r.reasoning.on, "budget": r.reasoning.budget ?? -1],
        ]
        if let c = r.toolChoice { obj["tool_choice"] = "\(c)" }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    static func decimal(_ f: Float) -> Double { Double("\(f)") ?? Double(f) }
}

/// The model fingerprint stored as `model_sha` (cached per path; the dev store never rewrites a pinned model).
public enum ModelManifestSHA {
    private static let cache = Mutex<[String: String]>([:])

    public static func sha(for slot: ModelSlot) -> String? {
        let key = slot.path
        if let hit = cache.withLock({ $0[key] }) { return hit }
        guard let v = compute(slot) else { return nil }
        cache.withLock { $0[key] = v }
        return v
    }

    static func hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static func compute(_ slot: ModelSlot) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: slot.path, isDirectory: &isDir) else { return nil }
        let url = URL(fileURLWithPath: slot.path)
        if !isDir.boolValue, slot.engine == .scripted { return (try? Data(contentsOf: url)).map(hex) }
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        if let m = manifest(dir.appendingPathComponent(".hf-fetch.json")) { return m }
        // No manifest: names + sizes of the files (cheap, changes with any replaced weight file).
        let items = (try? fm.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        let listing = items.filter { !$0.hasPrefix(".") }.map { name -> String in
            let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? -1
            return "\(name)\t\(size)"
        }.joined(separator: "\n")
        return hex(Data(listing.utf8))
    }

    /// Canonical `.hf-fetch.json`: {repo, commit, files: [[path, oid, lfs oid]]} sorted by path.
    static func manifest(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
            let repo = o["repo"] as? String, let commit = o["commit"] as? String
        else { return nil }
        let files = (o["files"] as? [[String: Any]] ?? []).compactMap { f -> [String]? in
            guard let p = f["path"] as? String else { return nil }
            return [p, f["oid"] as? String ?? "", (f["lfs"] as? [String: Any])?["oid"] as? String ?? ""]
        }.sorted { $0[0] < $1[0] }
        let canon: [String: Any] = ["repo": repo, "commit": commit, "files": files]
        guard let c = try? JSONSerialization.data(withJSONObject: canon, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return hex(c)
    }
}
