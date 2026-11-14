// M2.T05 (R-220, NFR-SEC2; blueprint E §E.2.2): the signed catalog, schema 2, as the app decodes it. Wire format
// = tools/catalog-tool/Sources/catalog-tool/Manifest.swift and catalog/schema/catalog-v2.schema.json.
// NFR-SEC2 enforcement point: decoding rejects any entry whose `format` is not safetensors / GGUF / Core ML / ONNX
// and any file that is pickle or Python (`.bin` outside a compiled Core ML bundle unless declared a raw tensor
// file, `.pt`, `.pth`, `.pkl`, `.pickle`, `.ckpt`, `.py`).
import Darwin
import Foundation

public enum CatalogSchemaError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case forbiddenFormat(model: String, format: String)
    case forbiddenFile(model: String, path: String)
}

public struct ModelCatalog: Codable, Sendable, Equatable {
    public var schema: Int
    public var catalogVersion: Int
    public var issued: Date
    public var expires: Date
    public var minAppVersion: String
    public var revoked: [CatalogRevocation]
    public var roles: [String]
    public var toneSentence: String
    public var onDemand: [String]
    /// Cell key (`T0`, `T2-24`, …) → speed class → cell.
    public var assignments: [String: [SpeedClass: CatalogCell]]
    public var models: [String: CatalogModel]
    /// M6.T16 (D-026): downloadable runtime components (`catalog/runtimes.yaml`); empty when the catalog has none.
    public var runtimes: [CatalogRuntime]

    enum CodingKeys: String, CodingKey {
        case schema, issued, expires, revoked, roles, assignments, models, runtimes
        case catalogVersion = "catalog_version", minAppVersion = "min_app_version", toneSentence = "tone_sentence", onDemand = "on_demand"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        guard schema == 2 else { throw CatalogSchemaError.unsupportedSchema(schema) }
        catalogVersion = try c.decode(Int.self, forKey: .catalogVersion)
        issued = try c.decode(Date.self, forKey: .issued)
        expires = try c.decode(Date.self, forKey: .expires)
        minAppVersion = try c.decode(String.self, forKey: .minAppVersion)
        revoked = try c.decode([CatalogRevocation].self, forKey: .revoked)
        roles = try c.decode([String].self, forKey: .roles)
        toneSentence = try c.decode(String.self, forKey: .toneSentence)
        onDemand = try c.decodeIfPresent([String].self, forKey: .onDemand) ?? []
        let raw = try c.decode([String: [String: CatalogCell]].self, forKey: .assignments)
        assignments = raw.mapValues { Dictionary(uniqueKeysWithValues: $0.compactMap { k, v in SpeedClass(rawValue: k).map { ($0, v) } }) }
        var models = try c.decode([String: CatalogModel].self, forKey: .models)
        for (id, var m) in models { m.id = id; models[id] = m }
        self.models = models
        for (id, m) in models { try m.validateFormats(id: id) }
        runtimes = try c.decodeIfPresent([CatalogRuntime].self, forKey: .runtimes) ?? []
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema); try c.encode(catalogVersion, forKey: .catalogVersion)
        try c.encode(issued, forKey: .issued); try c.encode(expires, forKey: .expires)
        try c.encode(minAppVersion, forKey: .minAppVersion); try c.encode(revoked, forKey: .revoked)
        try c.encode(roles, forKey: .roles); try c.encode(toneSentence, forKey: .toneSentence); try c.encode(onDemand, forKey: .onDemand)
        try c.encode(assignments.mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }, forKey: .assignments)
        try c.encode(models, forKey: .models)
        if !runtimes.isEmpty { try c.encode(runtimes, forKey: .runtimes) }
    }

    /// The runtime component `name` (`filetools-runtime`, `video-runtime`), if the catalog lists it.
    public func runtime(_ name: String) -> CatalogRuntime? { runtimes.first { $0.name == name } }

    /// Decodes catalog bytes (ISO-8601 dates).
    public static func decode(_ data: Data) throws -> ModelCatalog {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(ModelCatalog.self, from: data)
    }

    public func isExpired(at now: Date) -> Bool { now > expires }

    public func revocation(for id: String) -> CatalogRevocation? { revoked.first { $0.id == id } }

    /// The cell for a Mac: the largest sub-band key of its tier whose minimum RAM ≤ the Mac's RAM (`T3-64` on a
    /// 64 GB Mac, `T3-48` on 48 GB), else the bare tier key; then its speed class, else the closest lower one
    /// (blueprint E §E.2.3 step 1).
    public func cell(tier: HardwareTier, ramGB: Int, speedClass: SpeedClass) -> (key: String, cell: CatalogCell)? {
        let candidates = assignments.keys.compactMap { k -> (String, Int)? in
            if k == tier.rawValue { return (k, 0) }
            guard k.hasPrefix(tier.rawValue + "-"), let min = Int(k.dropFirst(tier.rawValue.count + 1)) else { return nil }
            return (k, min)
        }
        let fitting = candidates.filter { $0.1 <= ramGB }
        guard let key = (fitting.max { $0.1 < $1.1 } ?? candidates.min { $0.1 < $1.1 })?.0, let classes = assignments[key] else { return nil }
        for sc in SpeedClass.allCases.reversed() where sc <= speedClass {
            if let c = classes[sc] { return (key, c) }
        }
        return classes.min { $0.key < $1.key }.map { (key, $0.value) }
    }
}

/// One runtime component (M6.T16; catalog `runtimes[]`, format defined by `catalog/runtimes.yaml`). Generic: the
/// installer knows nothing about what runs inside (File tools Python now, the video runtime in M5.T01).
public struct CatalogRuntime: Codable, Sendable, Equatable {
    public enum SignatureMode: String, Codable, Sendable { case adhoc, dev, devid }
    public var name: String
    public var version: String
    public var sha256: String
    public var sizeBytes: Int64
    public var url: String
    public var minAppVersion: String
    public var tiers: [String]
    public var signatureMode: SignatureMode

    enum CodingKeys: String, CodingKey {
        case name, version, sha256, url, tiers
        case sizeBytes = "size_bytes", minAppVersion = "min_app_version", signatureMode = "signature_mode"
    }

    public init(name: String, version: String, sha256: String, sizeBytes: Int64, url: String, minAppVersion: String = "0.0.1",
                tiers: [String] = ["T0", "T1", "T2", "T3", "T4"], signatureMode: SignatureMode = .adhoc) {
        self.name = name; self.version = version; self.sha256 = sha256; self.sizeBytes = sizeBytes; self.url = url
        self.minAppVersion = minAppVersion; self.tiers = tiers; self.signatureMode = signatureMode
    }

    /// `<name>@<version>`: the install folder under `Runtimes/` (architecture §5.3).
    public var folderName: String { "\(name)@\(version)" }
}

public struct CatalogRevocation: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case disable, warn }
    public var id: String
    public var action: Action
    public var reason: String
}

public struct CatalogCell: Codable, Sendable, Equatable {
    public var chat: CatalogChatSlot
    public var embed: String?
    public var embedReason: String?
    public var rerank: String?
    public var rerankReason: String?
    /// M3.T05: WhisperKit (`stt-multi`) for languages outside Parakeet's 25; Voice pack, role `stt_multi` on demand.
    public var sttMulti: String?
    public var sttMultiReason: String?
    /// A model id, or an alias: `@chat_fast` / `@chat`.
    public var title: String
    public var csamCheck: String?
    /// AT-250 c2 (A-M7-T03c): the citation entailment model (Chat pack, role `cite_check`, on demand).
    public var citeCheck: String?
    public var csamCheckReason: String?
    public var voice: CatalogPackSlot?
    public var voiceReason: String?
    public var photo: CatalogPackSlot?
    public var photoReason: String?
    public var video: CatalogPackSlot?
    public var videoReason: String?
    enum CodingKeys: String, CodingKey {
        case chat, embed, rerank, title, voice, photo, video
        case embedReason = "embed_reason", rerankReason = "rerank_reason", csamCheck = "csam_check"
        case sttMulti = "stt_multi", sttMultiReason = "stt_multi_reason", citeCheck = "cite_check"
        case csamCheckReason = "csam_check_reason", voiceReason = "voice_reason", photoReason = "photo_reason", videoReason = "video_reason"
    }
}

public struct CatalogChatSlot: Codable, Sendable, Equatable {
    public var normal: CatalogChatPick?
    public var normalReason: String?
    public var evil: CatalogChatPick?
    public var evilReason: String?
    public var evilFamilyReason: String?
    public var fastFirst: String
    enum CodingKeys: String, CodingKey {
        case normal, evil
        case normalReason = "normal_reason", evilReason = "evil_reason", evilFamilyReason = "evil_family_reason", fastFirst = "fast_first"
    }
}

public struct CatalogChatPick: Codable, Sendable, Equatable {
    public var model: String
    public var ctx: Int
    public var stepDown: String?
    enum CodingKeys: String, CodingKey { case model, ctx, stepDown = "step_down" }
}

public struct CatalogPackSlot: Codable, Sendable, Equatable {
    public var normal: [String]
    public var evil: [String]
}

public struct CatalogModel: Codable, Sendable, Equatable {
    public static let allowedFormats: Set<String> = ["mlx-safetensors", "safetensors", "gguf", "mlmodelc", "mlpackage", "onnx"]

    /// The catalog key (filled from the `models` map).
    public var id: String = ""
    public var role: String
    public var engine: String
    public var engineMin: String?
    public var format: String
    public var quant: String?
    public var contextDefault: Int?
    public var contextMax: Int?
    public var capabilities: [String]
    public var footprint: CatalogFootprint
    public var family: String?
    public var chatTemplate: String?
    public var sharedGroup: String?
    public var requires: [String]?
    public var rawTensorFiles: [String]?
    public var supersedes: [String]?
    public var releaseNotes: String?
    public var license: String?
    public var licenseURL: String?
    public var attribution: String?
    public var modificationNotice: String?
    public var noncommercialOK: Bool
    public var repo: String
    public var commit: String
    public var files: [CatalogFile]

    enum CodingKeys: String, CodingKey {
        case role, engine, format, quant, capabilities, footprint, family, requires, supersedes, license, attribution, repo, commit, files
        case engineMin = "engine_min", contextDefault = "context_default", contextMax = "context_max", chatTemplate = "chat_template"
        case sharedGroup = "shared_group", rawTensorFiles = "raw_tensor_files", releaseNotes = "release_notes"
        case licenseURL = "license_url", modificationNotice = "modification_notice", noncommercialOK = "noncommercial_ok"
    }

    /// Σ file sizes in bytes.
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// The pickle / remote-code rule (NFR-SEC2), shared with `catalog-tool lint`.
    public static func forbiddenFile(_ path: String, rawTensors: [String] = []) -> Bool {
        let lower = path.lowercased()
        if [".py", ".pt", ".pth", ".pkl", ".pickle", ".ckpt", ".h5"].contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.hasSuffix(".bin") {
            if lower.contains(".mlmodelc/") || lower.contains(".mlpackage/") { return false }
            return !rawTensors.contains { fnmatch($0, path, 0) == 0 }
        }
        return false
    }

    func validateFormats(id: String) throws {
        guard Self.allowedFormats.contains(format) else { throw CatalogSchemaError.forbiddenFormat(model: id, format: format) }
        for f in files where Self.forbiddenFile(f.path, rawTensors: rawTensorFiles ?? []) {
            throw CatalogSchemaError.forbiddenFile(model: id, path: f.path)
        }
    }
}

public struct CatalogFootprint: Codable, Sendable, Equatable {
    public var weightsGB: Double
    public var kvPerTokenKB: Double
    public var overheadGB: Double
    /// Bytes read per decoded token (GB); dense models default to the weights.
    public var activeGB: Double?
    enum CodingKeys: String, CodingKey {
        case weightsGB = "weights_gb", kvPerTokenKB = "kv_per_token_kb", overheadGB = "overhead_gb", activeGB = "active_gb"
    }
}

public struct CatalogFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public var sha256: String
    /// In order: the first that works is used (R-220 AC3, D-007: HF commit URLs).
    public var sources: [String]
    /// Optional per-chunk sha256 (E.2.2 `chunk{}`), checked as each chunk lands (M2.T08).
    public var chunk: CatalogChunk?

    public init(path: String, size: Int64, sha256: String, sources: [String], chunk: CatalogChunk? = nil) {
        self.path = path; self.size = size; self.sha256 = sha256; self.sources = sources; self.chunk = chunk
    }
}

public struct CatalogChunk: Codable, Sendable, Equatable {
    public var size: Int64
    public var sha256: [String]
    public init(size: Int64, sha256: [String]) { self.size = size; self.sha256 = sha256 }
}
