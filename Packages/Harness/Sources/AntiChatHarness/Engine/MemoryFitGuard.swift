// MemoryFitGuard (M1.T12 step 7; NFR-R5, R-208 AC3): the app-side "never crash on OOM, fall back first" check
// before a chat load. Footprint of a catalog entry = file size × 1.2 + KV estimate at its context; it must fit
// both the tier budget B (`-FakeHardware` / dev tier; NFR-R1 values, hardware-tiers §2.2, 1 GB = 1e9 B) and the
// memory free right now. If it does not, the next smaller installed entry of the same slot (`smaller` chain of
// catalog/dev.yaml) is used and the reply gets `model.usingLighter`; if none fits, the turn ends with
// `model.notEnoughMemory` + [Retry] before anything reaches the helper (no load attempted). The full
// fit-or-evict scheduler across engines is M2 (G-011).
// Free memory: `os_proc_available_memory` (named in the step) is API_UNAVAILABLE(macos) in the macOS 26 SDK
// (usr/include/os/proc.h:85), so the probe is `host_statistics64` free + inactive + purgeable + speculative pages
// (A-M1-T12a), the memory the kernel can hand out without paging out active data.
import AntiChatEngineProtocol
import AntiChatFoundation
import Darwin
import Foundation

public struct MemoryFitGuard: Sendable {
    /// One `catalog/dev-catalog.json` `catalog` entry (the fields the guard needs).
    public struct Entry: Codable, Sendable, Hashable {
        public var key: String
        public var slot: String
        public var engine: String
        public var sizeGB: Double
        public var context: Int?
        public var smaller: String?

        enum CodingKeys: String, CodingKey { case key, slot, engine, sizeGB = "size_gb", context, smaller }

        public init(key: String, slot: String, engine: String, sizeGB: Double, context: Int? = nil, smaller: String? = nil) {
            self.key = key
            self.slot = slot
            self.engine = engine
            self.sizeGB = sizeGB
            self.context = context
            self.smaller = smaller
        }
    }

    public enum Decision: Sendable, Equatable {
        case fits(ModelSlot)
        /// Use `ModelSlot` (lighter) instead of the requested key `from`.
        case lighter(ModelSlot, from: String)
        case notEnoughMemory(AntiChatError)
    }

    public var entries: [String: Entry]
    /// Tier budget B in bytes; nil = no tier cap (only free memory counts).
    public var budgetBytes: UInt64?
    public var freeMemory: @Sendable () -> UInt64
    /// The installed slot for an entry (nil = not installed, skipped as a fallback).
    public var resolve: @Sendable (Entry) -> ModelSlot?
    /// KV bytes per context token when the model has no readable config (`[ASSUMPTION]`, a 9B-class GQA model
    /// at fp16 ≈ 2 × 36 layers × 4 KV heads × 128 × 2 B ≈ 72 KB, rounded up).
    public var fallbackKVBytesPerToken: UInt64 = 96 * 1024

    public init(
        entries: [String: Entry], budgetBytes: UInt64?, freeMemory: @escaping @Sendable () -> UInt64 = MemoryFitGuard.availableMemory,
        resolve: @escaping @Sendable (Entry) -> ModelSlot?
    ) {
        self.entries = entries
        self.budgetBytes = budgetBytes
        self.freeMemory = freeMemory
        self.resolve = resolve
    }

    // MARK: - Arithmetic

    /// File size × 1.2 + KV at the entry's context (or the slot's, when given).
    public func footprint(_ e: Entry, slot: ModelSlot? = nil) -> UInt64 {
        let weights = UInt64(e.sizeGB * 1e9 * 1.2)
        let ctx = UInt64(slot?.contextTokens ?? e.context ?? 4096)
        return weights + ctx * kvBytesPerToken(slot)
    }

    func kvBytesPerToken(_ slot: ModelSlot?) -> UInt64 {
        guard let slot, let cfg = Self.readConfig(slot.path) else { return fallbackKVBytesPerToken }
        return cfg
    }

    /// 2 (K, V) × layers × KV heads × head dim × 2 bytes (fp16), from an MLX model directory's config.json.
    static func readConfig(_ path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path).appendingPathComponent("config.json")
        guard let d = try? Data(contentsOf: url), var obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return nil
        }
        if let text = obj["text_config"] as? [String: Any] { obj.merge(text) { _, new in new } }
        guard let layers = obj["num_hidden_layers"] as? Int, let heads = obj["num_attention_heads"] as? Int else { return nil }
        let kv = obj["num_key_value_heads"] as? Int ?? heads
        let headDim = obj["head_dim"] as? Int ?? ((obj["hidden_size"] as? Int ?? 0) / max(heads, 1))
        guard headDim > 0 else { return nil }
        return UInt64(2 * layers * kv * headDim * 2)
    }

    /// The smaller of B and the free memory.
    public var limitBytes: UInt64 {
        let free = freeMemory()
        guard let b = budgetBytes, b > 0 else { return free }
        return min(b, free)
    }

    // MARK: - Decision

    public func check(_ slot: ModelSlot) -> Decision {
        // Scripted slots and keys the catalog does not know (dev paths, tests) are not the guard's business.
        guard let entry = entries[slot.key] else { return .fits(slot) }
        let limit = limitBytes
        let need = footprint(entry, slot: slot)
        if need <= limit { return .fits(slot) }
        var seen: Set<String> = [entry.key]
        var next = entry.smaller
        while let key = next, !seen.contains(key), let e = entries[key] {
            seen.insert(key)
            next = e.smaller
            guard e.slot == entry.slot, var candidate = resolve(e) else { continue }
            if candidate.contextTokens == nil { candidate.contextTokens = e.context }
            if footprint(e, slot: candidate) <= limit {
                return .lighter(candidate, from: entry.key)
            }
        }
        return .notEnoughMemory(
            AntiChatError(
                .modelNotEnoughMemory,
                detail: "\(entry.key) needs \(need / 1_000_000) MB > limit \(limit / 1_000_000) MB (B \(budgetBytes.map { "\($0 / 1_000_000) MB" } ?? "none"))"))
    }

    // MARK: - Inputs

    /// NFR-R1 tier budget B for a `-FakeHardware` tier (the smallest variant of the tier: T2 16 GB, T3 36 GB,
    /// T4 72 GB) in bytes.
    public static func budget(for tier: LaunchOptions.Tier) -> UInt64 {
        let gb: Double = switch tier {
        case .T0: 4.0
        case .T1: 9.5
        case .T2: 16
        case .T3: 36
        case .T4: 72
        }
        return UInt64(gb * 1e9)
    }

    /// Free + inactive + purgeable + speculative pages (bytes).
    public static func availableMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(getpagesize())
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count)
            + UInt64(stats.speculative_count)
        return pages * page
    }

    /// `catalog/dev-catalog.json` → entries by key.
    public static func loadDevCatalog(_ url: URL) throws -> [String: Entry] {
        let data = try Data(contentsOf: url)
        struct Raw: Decodable {
            var catalog: [String: RawEntry]
        }
        struct RawEntry: Decodable {
            var slot: String
            var engine: String
            var size_gb: Double
            var context: Int?
            var smaller: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        var out: [String: Entry] = [:]
        for (k, v) in raw.catalog {
            out[k] = Entry(key: k, slot: v.slot, engine: v.engine, sizeGB: v.size_gb, context: v.context, smaller: v.smaller)
        }
        return out
    }

    /// Dev model directory `<models>/<key>` (tools/dev/hf-fetch.py layout; `$ANTICHAT_DEV_CACHE/Models` or
    /// `~/Library/Application Support/AntiChat-Dev/Models`) → slot, when installed.
    public static func devResolver(modelsDir: URL? = nil) -> @Sendable (Entry) -> ModelSlot? {
        let dir = modelsDir ?? {
            if let c = ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"], !c.isEmpty {
                return URL(fileURLWithPath: c).appendingPathComponent("Models")
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AntiChat-Dev/Models")
        }()
        return { e in
            let d = dir.appendingPathComponent(e.key)
            guard FileManager.default.fileExists(atPath: d.path) else { return nil }
            let engine = EngineKind(rawValue: e.engine) ?? .mlx
            return ModelSlot(engine: engine, key: e.key, path: d.path, footprintBytes: UInt64(e.sizeGB * 1e9 * 1.2), contextTokens: e.context)
        }
    }
}
