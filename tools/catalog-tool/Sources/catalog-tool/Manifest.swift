// M2.T04 (R-220 AC5; blueprint E §E.2.2): the emitted catalog, schema 2. Property names are the JSON keys
// (snake_case on purpose: this file *is* the wire format, mirrored by AntiChatPlatform/Catalog/CatalogSchema.swift
// and catalog/schema/catalog-v2.schema.json). Encoded with sorted keys so `make catalog` is byte-reproducible.
import Foundation

struct Manifest: Codable, Equatable {
    var schema = 2
    var catalog_version: Int
    var issued: String
    var expires: String
    var min_app_version: String
    var revoked: [Revocation]
    var roles: [String]
    var tone_sentence: String
    var on_demand: [String]
    /// cell key (`T2-24`) → speed class (`S1`…`S4`) → cell.
    var assignments: [String: [String: Cell]]
    var models: [String: ModelEntry]
    /// M6.T16 (D-026): downloadable runtime components (`catalog/runtimes.yaml`; File tools now, video in M5.T01).
    /// Absent (not empty) when the yaml has none, so older catalogs stay byte-identical.
    var runtimes: [RuntimeEntry]?
    /// M7.T01 (R-253): `catalog/search-engines.yaml` `engines`, verbatim (the app's AntiChatTools/SearchEngineConfig
    /// decodes it; catalog/schema/search-engines.schema.json validates it). Absent in catalogs built before M7.
    var search_engines: [JSONValue]? = nil
    /// M7.T06 (R-081 AC4): `catalog/mcp-curated.yaml` `servers`, verbatim (AntiChatTools/MCPCurated decodes it;
    /// catalog/schema/mcp-curated.schema.json validates it). Absent in catalogs built before M7.
    var mcp_curated: [JSONValue]? = nil
}

/// One runtime component (M6.T16; generic, media-agnostic). The zip at `url` unpacks to `Runtimes/<name>@<version>/`.
struct RuntimeEntry: Codable, Equatable {
    var name: String
    var version: String
    var sha256: String
    var size_bytes: Int64
    var url: String
    var min_app_version: String
    var tiers: [String]
    var signature_mode: String  // adhoc | dev | devid
}

/// Any JSON value, so a catalog section authored in YAML passes through with sorted keys (byte-reproducible).
indirect enum JSONValue: Codable, Equatable {
    case string(String), number(Double), int(Int), bool(Bool), null, array([JSONValue]), object([String: JSONValue])

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .int(let i): try c.encode(i)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// From a Yams-loaded tree (`[String: Any]`, `[Any]`, scalars).
    init(yaml any: Any?) throws {
        switch any {
        case nil, is NSNull: self = .null
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .number(d)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map { try JSONValue(yaml: $0) })
        case let o as [String: Any]: self = .object(try o.mapValues { try JSONValue(yaml: $0) })
        default: throw ToolError.message("search-engines.yaml: unsupported value \(String(describing: any))")
        }
    }
}

struct Revocation: Codable, Equatable {
    var id: String
    var action: String  // disable | warn
    var reason: String  // corrupt | license | takedown
}

struct Cell: Codable, Equatable {
    var chat: ChatSlot
    var embed: String?
    var embed_reason: String?
    var rerank: String?
    var rerank_reason: String?
    /// M3.T05: WhisperKit for languages outside Parakeet's 25 (Voice pack, on demand).
    var stt_multi: String?
    var stt_multi_reason: String?
    var title: String
    var csam_check: String?
    var csam_check_reason: String?
    /// AT-250 c2 (A-M7-T03c): the citation entailment model (Chat pack, on demand; same model on every cell).
    var cite_check: String?
    var voice: PackSlot?
    var voice_reason: String?
    var photo: PackSlot?
    var photo_reason: String?
    var video: PackSlot?
    var video_reason: String?
}

struct ChatSlot: Codable, Equatable {
    var normal: ChatPick?
    var normal_reason: String?
    var evil: ChatPick?
    var evil_reason: String?
    var evil_family_reason: String?
    var fast_first: String
}

struct ChatPick: Codable, Equatable {
    var model: String
    var ctx: Int
    var step_down: String?
}

/// A non-chat pack per mode: ordered model ids (the first is the default; `requires` adds companions).
struct PackSlot: Codable, Equatable {
    var normal: [String]
    var evil: [String]
}

struct ModelEntry: Codable, Equatable {
    var role: String
    var engine: String
    var engine_min: String?
    var format: String
    var quant: String?
    var context_default: Int?
    var context_max: Int?
    var capabilities: [String]
    var footprint: Footprint
    var family: String?
    var chat_template: String?
    var shared_group: String?
    var requires: [String]?
    /// Globs of `.bin` files that are raw tensors read by the engine (Kokoro voice packs), never pickle (NFR-SEC2).
    var raw_tensor_files: [String]?
    var supersedes: [String]?
    var release_notes: String?
    var license: String?
    var license_url: String?
    var attribution: String?
    var modification_notice: String?
    var noncommercial_ok: Bool
    var repo: String
    var commit: String
    var files: [FileEntry]
}

struct Footprint: Codable, Equatable {
    var weights_gb: Double
    var kv_per_token_kb: Double
    var overhead_gb: Double
    var active_gb: Double?
}

struct FileEntry: Codable, Equatable {
    var path: String
    var size: Int64
    var sha256: String
    var sources: [String]
    var chunk: Chunk?
}

struct Chunk: Codable, Equatable {
    var size: Int64
    var sha256: [String]
}

extension Manifest {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    func encoded() throws -> Data { try Self.encoder().encode(self) + Data("\n".utf8) }

    static func load(_ url: URL) throws -> Manifest { try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)) }

    /// The same catalog with the fields that change on every build cleared (reproducibility comparison).
    var content: Manifest {
        var m = self
        m.catalog_version = 0; m.issued = ""; m.expires = ""
        return m
    }
}

/// `catalog/catalog.lock.json`: what HF said for every key at its commit (sizes, sha256, git oids, gated).
struct Lock: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var repo: String
        var commit: String
        var gated: Bool
        var files: [LockFile]
    }
    struct LockFile: Codable, Equatable {
        var path: String
        var size: Int64
        var sha256: String
        /// git blob id for non-LFS files (their sha256 was computed once from an anonymous download).
        var oid: String?
    }
    var _doc = "GENERATED by `catalog-tool build` (make catalog); `make catalog CHECK=1` re-resolves it against Hugging Face."
    var models: [String: Entry]
}
