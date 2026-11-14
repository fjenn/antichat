// M8.T10 step 2 (R-205 AC1–AC2, NFR-D8): what AntiChat uses on disk, in eight categories (never "Other"). Each file
// under the documented paths is counted once by `totalFileAllocatedSize` (the block accounting of `du -sk`; a hard
// link once, an APFS clone per file as `du` does) and lands in exactly one category:
//   model blobs by the first `model_install` slot (pack × mode, slot order) whose manifest names them — a blob shared
//   by several slots is counted once and flagged "shared" on the other rows; Evil-mode slots → Evil variants;
//   `antichat.sqlite*`, `Backups/` and the Media files of project files → Chats & projects; the rest of `Media/` →
//   Media library; everything else (caches, logs, orphan blobs, partial downloads, runtimes, catalog) → Caches & logs.
// Computed off-main; `StorageModel` (UI) caches it and refreshes on [Refresh] / after a change / when older than 60 s.
import AntiChatStorage
import Foundation
import GRDB

public enum StorageCategory: String, Sendable, CaseIterable, Codable {
    case chatModels = "chat", voice, photo, video, evil, chats, media, caches

    /// `storage.cat.<raw>` (copy-deck §9).
    public var copyKey: String { "storage.cat.\(rawValue)" }

    static func forSlot(_ slot: String) -> StorageCategory {
        let parts = slot.split(separator: "/").map(String.init)  // <pack>/<mode>/<role>
        if parts.count > 1, parts[1] == "evil" { return .evil }
        switch parts.first ?? "" {
        case "voice": return .voice
        case "photo": return .photo
        case "video": return .video
        default: return .chatModels
        }
    }
}

/// VQ (S-21 Storage): where AntiChat keeps data, in the friendly groups Settings › Storage lists (one label, one size,
/// one Show in Finder each; the raw paths stay behind Show in Finder). Every `DataPaths.Kind` lands in exactly one.
public enum StorageLocation: String, Sendable, CaseIterable, Codable {
    case library, models, caches, logs, preferences, fileTools

    /// `storage.loc.<raw>` (copy-deck §9).
    public var copyKey: String { "storage.loc.\(rawValue)" }

    public static func of(_ kind: DataPaths.Kind) -> StorageLocation {
        switch kind {
        case .container: .library
        case .models, .modelsInternal: .models
        case .caches, .bundleCaches, .httpStorages, .webKit, .incognitoTemp: .caches
        case .logs, .crashReports: .logs
        case .preferences, .savedState: .preferences
        case .fileToolsContainers: .fileTools
        }
    }
}

public struct StorageReport: Sendable, Equatable, Codable {
    public struct ModelRow: Sendable, Equatable, Codable, Identifiable {
        public var slot: String
        public var modelID: String
        public var pack: String
        public var mode: String
        /// The slot's role (`chat`, `embed`, `rerank`, `chat_fast`, `voice`, …; "" when unknown).
        public var role: String = ""
        public var category: StorageCategory
        /// Bytes this row's blobs take, each blob counted on the first row that names it.
        public var bytes: Int64
        /// Some of its files are counted on an earlier row (shared tokenizer, encoder …).
        public var shared: Bool
        /// Some of the files its install view names are on no disk (a link into a store that is gone).
        public var missing: Bool = false
        public var installView: URL
        public var id: String { slot }

        public init(slot: String, modelID: String, pack: String, mode: String, role: String = "", category: StorageCategory,
                    bytes: Int64, shared: Bool, missing: Bool = false, installView: URL) {
            self.slot = slot; self.modelID = modelID; self.pack = pack; self.mode = mode; self.role = role
            self.category = category; self.bytes = bytes; self.shared = shared; self.missing = missing; self.installView = installView
        }
    }

    public var bytes: [StorageCategory: Int64]
    public var total: Int64
    public var models: [ModelRow]
    public var freeBytes: Int64?
    public var measuredAt: Date
    /// Bytes per friendly location (the Models folder counted under `.models` even inside the container).
    public var locations: [StorageLocation: Int64] = [:]

    public init(bytes: [StorageCategory: Int64], total: Int64, models: [ModelRow], freeBytes: Int64?, measuredAt: Date,
                locations: [StorageLocation: Int64] = [:]) {
        self.bytes = bytes; self.total = total; self.models = models; self.freeBytes = freeBytes; self.measuredAt = measuredAt
        self.locations = locations
    }

    public func json() -> Data {
        var obj: [String: Any] = ["total": total]
        for c in StorageCategory.allCases { obj[c.rawValue] = bytes[c] ?? 0 }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}

/// VQ (S-21 Storage, NFR-D8): what Settings › Capabilities knows about an install view (its pack and mode, from the
/// catalog selection), so a model installed without a `model_install` row (a container set up by the CLI or a copied
/// one) is still counted under its pack — the two pages show the same numbers.
public struct StorageInstallHint: Sendable, Equatable {
    public var pack: String
    public var mode: String
    /// The catalog slot's role (`chat`, `embed`, `rerank`, …), so the row says what the model is for.
    public var role: String
    public init(pack: String, mode: String, role: String = "") { self.pack = pack; self.mode = mode; self.role = role }
}

public enum StorageAccountant {
    public static func measure(_ paths: DataPaths, database: AppDatabase?, installs: [String: StorageInstallHint] = [:],
                               fileManager fm: FileManager = .default) -> StorageReport {
        measure(paths, reader: database?.writer, installs: installs, fileManager: fm)
    }

    /// Measures every documented path. `reader` (the chats DB; read-only is enough) gives the model slots and the
    /// project files; nil = project files as Media library. `installs` (model id → pack/mode) covers install views
    /// with no `model_install` row; a view known to neither is counted as Caches & logs.
    public static func measure(_ paths: DataPaths, reader database: (any DatabaseReader)?, installs: [String: StorageInstallHint] = [:],
                               fileManager fm: FileManager = .default) -> StorageReport {
        let models = ModelsDirectory(root: paths.models)
        var slots = (try? database?.read { db in
            try Row.fetchAll(db, sql: "SELECT slot, catalog_entry_id, manifest_sha FROM model_install ORDER BY slot")
                .map { (slot: $0["slot"] as String, id: $0["catalog_entry_id"] as String, sha: $0["manifest_sha"] as String) }
        }) ?? []
        let rowIDs = Set(slots.map(\.id))
        for (id, hint) in installs.sorted(by: { $0.key < $1.key }) where !rowIDs.contains(id)
            && fm.fileExists(atPath: models.install(id).path) {
            let role = hint.role.isEmpty ? "" : "\(hint.role)/"
            slots.append((slot: "\(hint.pack)/\(hint.mode)/\(role)\(id)", id: id, sha: ""))
        }
        let projectFiles = Set((try? database?.read { db in
            try String.fetchAll(db, sql: """
                SELECT b.path FROM project_file f JOIN file_blob b ON b.id = f.blob_id WHERE f.origin = 'copied'
                """)
        }) ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.path }

        // Blob → (category, owning slot), first slot wins (slots sorted by pack order then name).
        var blobOwner: [String: (StorageCategory, String)] = [:]
        var rowBlobs: [(row: StorageReport.ModelRow, blobs: Set<String>)] = []
        var linkTarget: [String: URL] = [:]  // blob → the real file an install view's link resolves to
        let ordered = slots.sorted { (order($0.slot), $0.slot) < (order($1.slot), $1.slot) }
        for s in ordered {
            let cat = StorageCategory.forSlot(s.slot)
            let manifest = (s.sha.isEmpty ? nil : InstallManifest.load(models.manifest(s.sha)))
                ?? InstallManifest.load(models.install(s.id).appending(path: "manifest.json"))
            let links = linkedTargets(models.install(s.id), fileManager: fm)
            let blobs = manifest?.blobs ?? Set(links.keys)
            for (b, u) in links where linkTarget[b] == nil { linkTarget[b] = u }
            var shared = false
            for b in blobs { if blobOwner[b] == nil { blobOwner[b] = (cat, s.slot) } else { shared = true } }
            let parts = s.slot.split(separator: "/").map(String.init)
            // `<pack>/<mode>/<role>` (model_install) or `<pack>/<mode>/[<role>/]<id>` (a hint).
            let role = parts.count > 3 || (parts.count == 3 && parts[2] != s.id) ? parts[2] : ""
            rowBlobs.append((StorageReport.ModelRow(
                slot: s.slot, modelID: s.id, pack: parts.first ?? "chat", mode: parts.count > 1 ? parts[1] : "normal", role: role,
                category: cat, bytes: 0, shared: shared, installView: models.install(s.id)), blobs))
        }
        let installCategory: [String: StorageCategory] = Dictionary(ordered.map { ($0.id, StorageCategory.forSlot($0.slot)) },
                                                                     uniquingKeysWith: { a, _ in a })

        var bytes: [StorageCategory: Int64] = [:]
        var perBlob: [String: Int64] = [:]
        var seenInodes = Set<UInt64>()
        let container = paths.container.standardizedFileURL.path
        let modelsRoot = models.root.standardizedFileURL.path
        let media = paths.container.appendingPathComponent("Media").standardizedFileURL.path

        func classify(_ path: String) -> StorageCategory {
            if path.hasPrefix(modelsRoot + "/") {
                let rel = String(path.dropFirst(modelsRoot.count + 1))
                let comps = rel.split(separator: "/").map(String.init)
                if comps.first == "store", let sha = comps.last, let o = blobOwner[sha] { return o.0 }
                if comps.first == "installs", comps.count > 1, let c = installCategory[comps[1]] { return c }
                return .caches
            }
            if path.hasPrefix(media + "/") { return projectFiles.contains(path) ? .chats : .media }
            if path.hasPrefix(container + "/") {
                let rel = String(path.dropFirst(container.count + 1))
                if rel.hasPrefix("antichat.sqlite") || rel.hasPrefix("Backups/") || rel == "Backups" { return .chats }
            }
            return .caches
        }

        // Every documented location once (a pattern expanded to its matches), with the kind it is listed under. The
        // extra Debug folders (`Caches/AntiChat-Dev`, the shared `Logs/AntiChat`) are AntiChat's data too.
        var roots: [(url: URL, kind: DataPaths.Kind)] = [(paths.container, .container)]
        if !paths.modelsAreInsideContainer { roots.append((paths.models, .models)) }
        roots += [(paths.caches, .caches), (paths.logs, .logs)]
        for e in paths.entries where !(e.kind == .container || (e.kind == .models && e.url == paths.models)) {
            if let pattern = e.pattern {
                roots += DataPaths.names(in: e.url, matching: pattern).map { (e.url.appendingPathComponent($0), e.kind) }
            } else {
                roots.append((e.url, e.kind))
            }
        }
        var seenRoots = Set<String>()
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey]
        var locations: [StorageLocation: Int64] = [:]
        var countedRoots: [String] = []
        for (root, kind) in roots.map({ ($0.url.standardizedFileURL, $0.kind) }).sorted(by: { $0.0.path < $1.0.path }) {
            guard seenRoots.insert(root.path).inserted, fm.fileExists(atPath: root.path) else { continue }
            countedRoots.append(realPath(root.path))
            var items: [URL] = [root]
            if let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) {
                for case let u as URL in e { items.append(u) }
            }
            for u in items {
                guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
                if v.isDirectory == true, v.isSymbolicLink != true { continue }
                var st = stat()
                if lstat(u.path, &st) == 0, st.st_nlink > 1 {
                    guard seenInodes.insert(UInt64(st.st_ino)).inserted else { continue }
                }
                let size = Int64(v.totalFileAllocatedSize ?? Int(st.st_blocks) * 512)
                let path = u.standardizedFileURL.path
                let cat = classify(path)
                bytes[cat, default: 0] += size
                locations[path.hasPrefix(modelsRoot + "/") ? .models : StorageLocation.of(kind), default: 0] += size
                if path.hasPrefix(modelsRoot + "/store/") { perBlob[u.lastPathComponent, default: 0] += size }
            }
        }
        // F1 (r66): an install view is links; a blob the store walk did not count (the link resolves outside the Models
        // folder: a store reached through a link, a moved or shared one) is measured at its real target, once per
        // inode. A target inside another counted folder (caches …) moves from that folder's category to the model's.
        var targetInodes = Set<String>()
        var targetBytes: [String: Int64] = [:]
        var missingBlobs = Set<String>()
        for (b, owner) in blobOwner.sorted(by: { $0.key < $1.key }) where perBlob[b] == nil {
            guard let u = linkTarget[b] else { missingBlobs.insert(b); continue }
            var st = stat()
            guard stat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { missingBlobs.insert(b); continue }
            guard targetInodes.insert("\(st.st_dev):\(st.st_ino)").inserted else { continue }
            let size = Int64(st.st_blocks) * 512
            targetBytes[b] = size
            let real = realPath(u.path)
            if countedRoots.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
                let old = classify(real)
                if old != owner.0 { bytes[old, default: 0] -= size; bytes[owner.0, default: 0] += size }
            } else {
                bytes[owner.0, default: 0] += size
                locations[.models, default: 0] += size
            }
        }
        let rows = rowBlobs.map { rb -> StorageReport.ModelRow in
            var r = rb.row
            r.bytes = rb.blobs.filter { blobOwner[$0]?.1 == r.slot }.reduce(0) { $0 + (perBlob[$1] ?? targetBytes[$1] ?? 0) }
            r.missing = rb.blobs.contains { missingBlobs.contains($0) }
            return r
        }
        let free = (try? paths.container.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        return StorageReport(bytes: bytes, total: bytes.values.reduce(0, +), models: rows, freeBytes: free, measuredAt: Date(),
                             locations: locations)
    }

    /// The store blobs an install view links to (a view with no manifest: its symlinks name the blobs).
    static func linkedBlobs(_ view: URL, fileManager fm: FileManager) -> Set<String> {
        Set(linkedTargets(view, fileManager: fm).keys)
    }

    /// Blob → the file its link points at (relative links resolved against the link's folder; not checked to exist).
    static func linkedTargets(_ view: URL, fileManager fm: FileManager) -> [String: URL] {
        guard let e = fm.enumerator(at: view, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return [:] }
        var out: [String: URL] = [:]
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            if let dest = try? fm.destinationOfSymbolicLink(atPath: u.path), dest.contains("store/") {
                let target = dest.hasPrefix("/") ? URL(fileURLWithPath: dest)
                    : u.deletingLastPathComponent().appendingPathComponent(dest)
                out[URL(fileURLWithPath: dest).lastPathComponent] = target.standardizedFileURL
            }
        }
        return out
    }

    /// `realpath(3)` (every link and `/tmp` → `/private/tmp` resolved), or the path itself when it does not exist.
    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    static func order(_ slot: String) -> Int {
        let pack = slot.split(separator: "/").first.map(String.init) ?? ""
        let mode = slot.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        let p = ["chat": 0, "voice": 1, "photo": 2, "video": 3][pack] ?? 4
        return (mode == "evil" ? 10 : 0) + p
    }
}
