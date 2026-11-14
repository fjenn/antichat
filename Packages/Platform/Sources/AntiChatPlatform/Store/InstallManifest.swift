// M2.T10 (R-293, blueprint E §E.2.6): what an install view contains — `installs/<model-id>/manifest.json`
// {model_id, catalog_version, engine, placement, files → sha256}. Every manifest is also kept content-addressed in
// `<Models>/manifests/<sha256>.json`, so `model_install.manifest_sha` / `previous_manifest_sha` (rollback window) name
// a manifest whose blobs the garbage collector keeps.
import CryptoKit
import Foundation

public struct InstallManifest: Codable, Sendable, Equatable {
    public var modelID: String
    public var catalogVersion: Int
    public var engine: String
    public var placement: FilePlacement
    /// Engine-expected relative path → blob sha256.
    public var files: [String: String]
    /// File sizes (load-time size check, NFR-S5).
    public var sizes: [String: Int64]
    /// Files the catalog declares raw tensors (the NFR-SEC2 `.bin` exception), re-checked at load.
    public var rawTensors: [String]

    enum CodingKeys: String, CodingKey {
        case engine, placement, files, sizes
        case rawTensors = "raw_tensor_files"
        case modelID = "model_id", catalogVersion = "catalog_version"
    }

    public init(model: CatalogModel, catalogVersion: Int) {
        modelID = model.id
        self.catalogVersion = catalogVersion
        engine = model.engine
        placement = InstallView.placement(engine: model.engine)
        files = Dictionary(uniqueKeysWithValues: model.files.map { ($0.path, $0.sha256) })
        sizes = Dictionary(uniqueKeysWithValues: model.files.map { ($0.path, $0.size) })
        rawTensors = model.rawTensorFiles ?? []
    }

    public var blobs: Set<String> { Set(files.values) }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? e.encode(self)) ?? Data()
    }

    /// sha256 of the encoded manifest (`model_install.manifest_sha`).
    public var sha256: String { Verify.hex(SHA256.hash(data: encoded())) }

    public static func load(_ url: URL) -> InstallManifest? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(InstallManifest.self, from: $0) }
    }
}

extension ModelsDirectory {
    public var manifests: URL { root.appending(path: "manifests", directoryHint: .isDirectory) }
    /// Views being written (`<id>.tmp`) or swapped out (`<id>.old`); same volume as `installs/`.
    public var staging: URL { root.appending(path: "staging", directoryHint: .isDirectory) }
    public func install(_ id: String) -> URL { installs.appending(path: id, directoryHint: .isDirectory) }
    public func manifest(_ sha: String) -> URL { manifests.appending(path: "\(sha).json") }

    /// Every complete install view's manifest (`.tmp` / `.old` leftovers ignored).
    public func installedManifests() -> [InstallManifest] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: installs.path)) ?? []
        return ids.filter { !$0.hasSuffix(".tmp") && !$0.hasSuffix(".old") && !$0.hasPrefix(".") }.sorted()
            .compactMap { InstallManifest.load(install($0).appending(path: "manifest.json")) }
    }

    /// Every store blob a symlink under `installs/` or `staging/` points at (GC roots, independent of any manifest).
    /// Symlinked directories are not followed; a link counts when its target's last component is a sha256 digest.
    public func linkedBlobs() -> Set<String> {
        var out = Set<String>()
        for root in [installs, staging] { out.formUnion(Self.linkedBlobs(under: root)) }
        return out
    }

    static func linkedBlobs(under root: URL, fileManager fm: FileManager = .default) -> Set<String> {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return [] }
        var out = Set<String>()
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: u.path) else { continue }
            let sha = (dest as NSString).lastPathComponent
            if Verify.isSHA256Hex(sha) { out.insert(sha) }
        }
        return out
    }
}
