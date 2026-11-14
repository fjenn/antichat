// M2.T04 step 3 (R-220, R-300 AC1; P-platform-02): models.yaml + assignments.yaml → schema-2 manifest + lockfile.
// Every entry is resolved anonymously against its pinned commit (HubClient with `tokenProvider: .none`): `gated` must be
// false, the tree gives size + LFS sha256, and non-LFS files are downloaded once and hashed (cached in the lock).
import CryptoKit
import Darwin
import Foundation
import HuggingFace
import Yams

enum ToolError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { m } else { "" } }
}

/// One `catalog/models.yaml` entry (authored fields only).
struct ModelSpec: Codable, Equatable {
    struct FootprintSpec: Codable, Equatable {
        var kv_per_token_kb: Double
        var overhead_gb: Double
        var active_gb: Double?
    }
    var key: String
    /// `github`: the file only exists upstream on GitHub (`raw.githubusercontent.com/<repo>/<commit>/…`, pinned by
    /// the 40-char commit like an HF entry; A-M0-T07a (e) / M5 review P1-1: TAEHV). nil = Hugging Face.
    var host: String?
    var repo: String
    var commit: String
    var files: [String]
    var role: String
    var engine: String
    var engine_min: String?
    var format: String
    var quant: String?
    var context_default: Int?
    var context_max: Int?
    var capabilities: [String]?
    var footprint: FootprintSpec
    var family: String?
    var chat_template: String?
    var shared_group: String?
    var requires: [String]?
    var raw_tensor_files: [String]?
    var license: String?
    var license_url: String?
    var attribution: String?
    var modification_notice: String?
    var noncommercial_ok: Bool?
}

enum Spec {
    /// YAML (anchors and `<<` merge keys resolved by Yams) → JSON-compatible values → `T`.
    static func decode<T: Decodable>(_ type: T.Type, yaml: String) throws -> T {
        guard let any = try Yams.load(yaml: yaml) else { throw ToolError.message("empty YAML") }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: jsonable(any)))
    }

    static func jsonable(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues(jsonable)
        case let d as [AnyHashable: Any]: return Dictionary(uniqueKeysWithValues: d.map { ("\($0.key)", jsonable($0.value)) })
        case let a as [Any]: return a.map(jsonable)
        case is NSNull: return NSNull()
        case let s as String: return s
        case let b as Bool: return b
        case let i as Int: return i
        case let d as Double: return d
        default: return "\(v)"
        }
    }

    /// `catalog/runtimes.yaml` → runtime entries (M6.T16). A missing file means no runtimes.
    static func runtimes(_ url: URL) throws -> [RuntimeEntry]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        struct File: Decodable { var runtimes: [RuntimeEntry]? }
        let list = try decode(File.self, yaml: String(contentsOf: url, encoding: .utf8)).runtimes ?? []
        var seen = Set<String>()
        for r in list where !seen.insert(r.name).inserted { throw ToolError.message("runtimes.yaml: duplicate name \(r.name)") }
        return list.isEmpty ? nil : list.sorted { $0.name < $1.name }
    }

    static func models(_ url: URL) throws -> [ModelSpec] {
        struct File: Decodable { var models: [ModelSpec] }
        let specs = try decode(File.self, yaml: String(contentsOf: url, encoding: .utf8)).models
        var seen = Set<String>()
        for s in specs where !seen.insert(s.key).inserted { throw ToolError.message("models.yaml: duplicate key \(s.key)") }
        return specs
    }

    /// `assignments.yaml` → the manifest's assignment block, every cell expanded to S1…S4 (a class inherits the
    /// next lower one and overrides only the keys it names).
    static func assignments(_ url: URL) throws -> (cells: [String: [String: Cell]], tone: String, roles: [String], onDemand: [String], csamReason: String) {
        guard let root = try Yams.load(yaml: String(contentsOf: url, encoding: .utf8)) as? [String: Any],
              let cells = root["cells"] as? [String: Any] else { throw ToolError.message("assignments.yaml: no `cells`") }
        let csam = root["csam_check"] as? [String: Any]
        let csamModel = csam?["model"] as? String
        let csamReason = (csam?["reason"] as? String) ?? "pending_M4"
        let citeModel = (root["cite_check"] as? [String: Any])?["model"] as? String
        var out: [String: [String: Cell]] = [:]
        for (key, value) in cells {
            guard let classes = value as? [String: Any], var current = classes["S1"] as? [String: Any] else {
                throw ToolError.message("assignments.yaml: cell \(key) has no S1")
            }
            var expanded: [String: Cell] = [:]
            for sc in ["S1", "S2", "S3", "S4"] {
                if sc != "S1", let over = classes[sc] as? [String: Any] { current.merge(over) { $1 } }
                expanded[sc] = try cell(current, key: "\(key)/\(sc)", csamModel: csamModel, csamReason: csamReason)
                expanded[sc]?.cite_check = citeModel
            }
            out[key] = expanded
        }
        return (out, root["tone_sentence"] as? String ?? "", root["roles"] as? [String] ?? [], root["on_demand"] as? [String] ?? [], csamReason)
    }

    static func cell(_ d: [String: Any], key: String, csamModel: String?, csamReason: String) throws -> Cell {
        func pick(_ v: Any?) throws -> ChatPick? {
            guard let p = v as? [String: Any] else { return nil }
            guard let m = p["model"] as? String, let ctx = p["ctx"] as? Int else { throw ToolError.message("\(key): chat pick needs model + ctx") }
            return ChatPick(model: m, ctx: ctx, step_down: p["step_down"] as? String)
        }
        guard let chat = d["chat"] as? [String: Any], let fast = chat["fast_first"] as? String else {
            throw ToolError.message("\(key): chat.fast_first missing")
        }
        func pack(_ name: String) -> PackSlot? {
            switch d[name] {
            case let ids as [String]: return PackSlot(normal: ids, evil: ids)  // Evil photo/video/voice = Normal (Q-009 a)
            case let m as [String: Any]:
                let n = m["normal"] as? [String] ?? []
                return PackSlot(normal: n, evil: m["evil"] as? [String] ?? n)
            default: return nil
            }
        }
        return Cell(
            chat: ChatSlot(normal: try pick(chat["normal"]), normal_reason: chat["normal_reason"] as? String,
                           evil: try pick(chat["evil"]), evil_reason: chat["evil_reason"] as? String,
                           evil_family_reason: chat["evil_family_reason"] as? String, fast_first: fast),
            embed: d["embed"] as? String, embed_reason: d["embed_reason"] as? String,
            rerank: d["rerank"] as? String, rerank_reason: d["rerank_reason"] as? String,
            stt_multi: d["stt_multi"] as? String, stt_multi_reason: d["stt_multi_reason"] as? String,
            title: d["title"] as? String ?? "@chat_fast",
            csam_check: csamModel, csam_check_reason: csamModel == nil ? csamReason : nil,
            voice: pack("voice"), voice_reason: d["voice_reason"] as? String,
            photo: pack("photo"), photo_reason: d["photo_reason"] as? String,
            video: pack("video"), video_reason: d["video_reason"] as? String)
    }
}

/// Glob as `fnmatch(3)` without FNM_PATHNAME: `*` also matches `/`.
func globMatch(_ pattern: String, _ path: String) -> Bool { fnmatch(pattern, path, 0) == 0 }

struct RemoteFile: Sendable { var path: String; var size: Int64; var sha256: String?; var oid: String? }

/// What the build needs from Hugging Face. Tests replace it (no network in unit tests).
protocol HubResolving: Sendable {
    func gated(repo: String, commit: String) async throws -> Bool
    func files(repo: String, commit: String) async throws -> [RemoteFile]
    func sha256(repo: String, commit: String, path: String) async throws -> String
}

/// Anonymous HF access: no token provider, no credentials, `/resolve/<40-char commit>/` URLs only (D-007).
struct AnonymousHub: HubResolving {
    static let host = URL(string: "https://huggingface.co")!
    // Build tool, never in the app: an ephemeral session (no cookies, no credential storage) instead of NetworkGate.
    static let session = URLSession(configuration: .ephemeral)
    let client: HubClient = { let session = AnonymousHub.session
        return HubClient(session: session, host: AnonymousHub.host, tokenProvider: .none, cache: nil) }()

    func gated(repo: String, commit: String) async throws -> Bool {
        let m = try await client.getModel(Repo.ID(stringLiteral: repo), revision: commit)
        switch m.gated { case .none, .some(.notGated): return false; default: return true }
    }

    func files(repo: String, commit: String) async throws -> [RemoteFile] {
        var out: [RemoteFile] = []
        for try await page in try await client.listAllTree(in: Repo.ID(stringLiteral: repo), revision: commit, recursive: true) {
            for e in page.items where e.type == .file {
                out.append(RemoteFile(path: e.path, size: Int64(e.effectiveSize ?? 0), sha256: e.lfs?.oid, oid: e.oid))
            }
        }
        return out
    }

    func sha256(repo: String, commit: String, path: String) async throws -> String {
        let (data, response) = try await AnonymousHub.session.data(from: sourceURL(repo: repo, commit: commit, path: path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolError.message("\(repo)/\(path): HTTP error") }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

func sourceURL(repo: String, commit: String, path: String, host: String? = nil) -> URL {
    let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    if host == GitHubRaw.name { return URL(string: "https://raw.githubusercontent.com/\(repo)/\(commit)/\(p)")! }
    return URL(string: "https://huggingface.co/\(repo)/resolve/\(commit)/\(p)")!
}

/// Anonymous GitHub access for `host: github` entries: the git tree at the pinned commit (path, size, blob id) and a
/// one-time anonymous download of each file to hash it (cached in the lock by blob id, like HF non-LFS files).
struct GitHubRaw: HubResolving {
    static let name = "github"

    func gated(repo: String, commit: String) async throws -> Bool { false }  // a public repo; no account exists

    func files(repo: String, commit: String) async throws -> [RemoteFile] {
        struct Tree: Decodable { struct Item: Decodable { var path: String; var type: String; var size: Int64?; var sha: String }
            var tree: [Item]; var truncated: Bool }
        let url = URL(string: "https://api.github.com/repos/\(repo)/git/trees/\(commit)?recursive=1")!
        let (data, response) = try await AnonymousHub.session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolError.message("\(repo)@\(commit): GitHub tree HTTP error") }
        let t = try JSONDecoder().decode(Tree.self, from: data)
        if t.truncated { throw ToolError.message("\(repo)@\(commit): GitHub tree truncated") }
        return t.tree.filter { $0.type == "blob" }.map { RemoteFile(path: $0.path, size: $0.size ?? 0, sha256: nil, oid: $0.sha) }
    }

    func sha256(repo: String, commit: String, path: String) async throws -> String {
        let (data, response) = try await AnonymousHub.session.data(from: sourceURL(repo: repo, commit: commit, path: path, host: Self.name))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolError.message("\(repo)/\(path): HTTP error") }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum Build {
    static let neverShipped: Set<String> = [".gitattributes", ".gitignore", ".DS_Store"]

    /// Resolves every spec at its commit. Literal (wildcard-free) includes must match a file.
    static func resolve(_ specs: [ModelSpec], hub: any HubResolving, github: any HubResolving = GitHubRaw(), lock: Lock?) async throws -> Lock {
        try await withThrowingTaskGroup(of: (String, Lock.Entry).self) { group in
            var pending = specs[...]
            var out: [String: Lock.Entry] = [:]
            func next() {
                guard let s = pending.popFirst() else { return }
                group.addTask { (s.key, try await resolve(s, hub: s.host == GitHubRaw.name ? github : hub, cached: lock?.models[s.key])) }
            }
            for _ in 0..<6 { next() }
            while let (k, e) = try await group.next() { out[k] = e; next() }
            return Lock(models: out)
        }
    }

    static func resolve(_ s: ModelSpec, hub: any HubResolving, cached: Lock.Entry?) async throws -> Lock.Entry {
        if let h = s.host, h != GitHubRaw.name { throw ToolError.message("\(s.key): unknown host \(h)") }
        guard s.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw ToolError.message("\(s.key): commit must be a full 40-char sha")
        }
        let gated = try await hub.gated(repo: s.repo, commit: s.commit)
        if gated { throw ToolError.message("\(s.key): \(s.repo)@\(s.commit) is gated (R-300 AC1: ungated repos only)") }
        let remote = try await hub.files(repo: s.repo, commit: s.commit).filter { f in
            !neverShipped.contains((f.path as NSString).lastPathComponent) && s.files.contains { globMatch($0, f.path) }
        }
        for g in s.files where !g.contains("*") && !g.contains("?") && !remote.contains(where: { $0.path == g }) {
            throw ToolError.message("\(s.key): \(g) not found at \(s.commit)")
        }
        if remote.isEmpty { throw ToolError.message("\(s.key): no files match \(s.files)") }
        let reuse = cached.flatMap { $0.commit == s.commit ? Dictionary($0.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a }) : nil } ?? [:]
        var files: [Lock.LockFile] = []
        for f in remote.sorted(by: { $0.path < $1.path }) {
            if let sha = f.sha256 {
                files.append(.init(path: f.path, size: f.size, sha256: sha, oid: nil))
            } else if let c = reuse[f.path], c.oid == f.oid, c.size == f.size {
                files.append(c)
            } else {
                files.append(.init(path: f.path, size: f.size, sha256: try await hub.sha256(repo: s.repo, commit: s.commit, path: f.path), oid: f.oid))
            }
        }
        return Lock.Entry(repo: s.repo, commit: s.commit, gated: gated, files: files)
    }

    static func entry(_ s: ModelSpec, lock: Lock.Entry) -> ModelEntry {
        let weights = Double(lock.files.reduce(Int64(0)) { $0 + $1.size }) / 1e9
        return ModelEntry(
            role: s.role, engine: s.engine, engine_min: s.engine_min, format: s.format, quant: s.quant,
            context_default: s.context_default, context_max: s.context_max, capabilities: s.capabilities ?? [],
            footprint: Footprint(weights_gb: (weights * 1000).rounded() / 1000, kv_per_token_kb: s.footprint.kv_per_token_kb,
                                 overhead_gb: s.footprint.overhead_gb, active_gb: s.footprint.active_gb),
            family: s.family, chat_template: s.chat_template, shared_group: s.shared_group, requires: s.requires,
            raw_tensor_files: s.raw_tensor_files, supersedes: nil, release_notes: nil, license: s.license, license_url: s.license_url, attribution: s.attribution,
            modification_notice: s.modification_notice, noncommercial_ok: s.noncommercial_ok ?? false,
            repo: s.repo, commit: s.commit,
            files: lock.files.map { FileEntry(path: $0.path, size: $0.size, sha256: $0.sha256,
                                              sources: [sourceURL(repo: s.repo, commit: s.commit, path: $0.path, host: s.host).absoluteString], chunk: nil) })
    }

    static func isoString(_ d: Date) -> String { d.formatted(.iso8601) }

    /// The manifest. `previous` (the published catalog) sets the version: identical content keeps its version and
    /// dates (byte-identical output); any change publishes `previous + 1` (never lower, rollback protection).
    /// M7.T01 (R-253): `catalog/search-engines.yaml` → the `search_engines` section (nil when the file is absent).
    static func searchEngines(_ url: URL?) throws -> [JSONValue]? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let root = try Yams.load(yaml: String(contentsOf: url, encoding: .utf8)) as? [String: Any],
              let engines = root["engines"] as? [Any] else { throw ToolError.message("search-engines.yaml: no `engines` list") }
        var ids = Set<String>()
        for case let e as [String: Any] in engines {
            let id = e["id"] as? String ?? ""
            guard !id.isEmpty, ids.insert(id).inserted else { throw ToolError.message("search-engines.yaml: missing or duplicate id \(id)") }
            if id.lowercased().contains("google") { throw ToolError.message("search-engines.yaml: no Google engine may ship (R-248 AC2)") }
        }
        return try engines.map { try JSONValue(yaml: $0) }
    }

    /// M7.T06 (R-081 AC4): `catalog/mcp-curated.yaml` → the `mcp_curated` section (nil when the file is absent).
    static func mcpCurated(_ url: URL?) throws -> [JSONValue]? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let root = try Yams.load(yaml: String(contentsOf: url, encoding: .utf8)) as? [String: Any],
              let servers = root["servers"] as? [Any] else { throw ToolError.message("mcp-curated.yaml: no `servers` list") }
        var ids = Set<String>()
        for case let s as [String: Any] in servers {
            let id = s["id"] as? String ?? ""
            guard !id.isEmpty, ids.insert(id).inserted else { throw ToolError.message("mcp-curated.yaml: missing or duplicate id \(id)") }
            guard (s["url"] as? String)?.hasPrefix("https://") == true else { throw ToolError.message("mcp-curated.yaml: \(id) is not https") }
            guard ["none", "token", "oauth"].contains(s["auth"] as? String ?? "") else { throw ToolError.message("mcp-curated.yaml: \(id) auth") }
        }
        if ids.count < 10 { throw ToolError.message("mcp-curated.yaml: fewer than 10 servers (R-081 AC4)") }
        return try servers.map { try JSONValue(yaml: $0) }
    }

    static func manifest(specs: [ModelSpec], lock: Lock, assignmentsURL: URL, issued: Date, previous: Manifest?,
                         version: Int? = nil, searchEnginesURL: URL? = nil, mcpCuratedURL: URL? = nil,
                         runtimes: [RuntimeEntry]? = nil) throws -> Manifest {
        let a = try Spec.assignments(assignmentsURL)
        var models: [String: ModelEntry] = [:]
        for s in specs {
            guard let l = lock.models[s.key] else { throw ToolError.message("\(s.key): not resolved") }
            models[s.key] = entry(s, lock: l)
        }
        let issuedString = isoString(issued)
        var m = Manifest(catalog_version: version ?? 1, issued: issuedString,
                         expires: isoString(issued.addingTimeInterval(90 * 86_400)), min_app_version: "1.0.0",
                         revoked: [], roles: a.roles, tone_sentence: a.tone, on_demand: a.onDemand,
                         assignments: a.cells, models: models, runtimes: runtimes,
                         search_engines: try searchEngines(searchEnginesURL), mcp_curated: try mcpCurated(mcpCuratedURL))
        if version == nil, let p = previous {
            if p.content == m.content { return p }
            m.catalog_version = p.catalog_version + 1
        }
        return m
    }
}
