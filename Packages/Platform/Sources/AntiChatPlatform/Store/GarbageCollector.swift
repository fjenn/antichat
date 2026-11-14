// Ported from ollama/ollama@4d22e65:manifest/manifest.go:436-640 (MIT) — mark-and-sweep over the manifests
// (`retainedBlobDigestsLocked` + `removeUnreferencedBlobs`), no stored reference counts (P-platform-04).
// M2.T10 step 4 (R-293, NFR-D5). Mark = blobs referenced by any `installs/*/manifest.json`, by the manifests the
// `model_install` slots point at (current and `previous_manifest_sha`, the rollback window) and by downloads still
// in the queue (their parts too). Sweep = every other blob, part, bitmap and manifest.
// Release review (GC must be conservative): every symlink under `installs/` and `staging/` that points at a store blob
// is a root too, whatever its view's manifest or slot says. A view whose `manifest.json` is missing or no longer
// decodes (a manifest written by a newer/older build, a damaged file, a hand-copied container) must not lose its
// files: a dangling symlink is a deleted model. Clone placements are independent copies, so they need no mark.
import AntiChatStorage
import Foundation
import GRDB

public struct GarbageCollector: Sendable {
    public struct Report: Sendable, Equatable {
        public var removedBlobs: [String] = []
        public var removedParts = 0
        public var freedBytes: Int64 = 0
    }

    public let models: ModelsDirectory
    public let database: AppDatabase?
    public init(models: ModelsDirectory, database: AppDatabase?) { self.models = models; self.database = database }

    /// The digests that must stay. `active` = sha256 of queued / running / paused downloads.
    public func marked(active: Set<String> = []) throws -> (blobs: Set<String>, manifests: Set<String>) {
        var blobs = models.linkedBlobs(), manifests = Set<String>()
        for m in models.installedManifests() {
            blobs.formUnion(m.blobs)
            manifests.insert(m.sha256)
        }
        if let database {
            let rows = try database.read { try ModelInstallRecord.fetchAll($0) }
            for r in rows { for sha in [r.manifestSHA, r.previousManifestSHA].compactMap({ $0 }) where Verify.isSHA256Hex(sha) {
                manifests.insert(sha)
                if let m = InstallManifest.load(models.manifest(sha)) { blobs.formUnion(m.blobs) }
            } }
        }
        blobs.formUnion(active)
        return (blobs, manifests)
    }

    /// Removes everything unmarked. `all` = also forget the rollback window (only installed views count).
    @discardableResult
    public func sweep(active: Set<String> = [], all: Bool = false) throws -> Report {
        var mark = try marked(active: active)
        if all {
            mark.blobs = Set(models.installedManifests().flatMap(\.blobs)).union(models.linkedBlobs()).union(active)
            mark.manifests = Set(models.installedManifests().map(\.sha256))
        }
        var r = Report()
        let store = BlobStore(models: models)
        for sha in store.all() where !mark.blobs.contains(sha) {
            r.freedBytes += SpaceAccountant.allocated(store.url(sha))
            try store.remove(sha)
            r.removedBlobs.append(sha)
        }
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: models.partial.path)) ?? [] {
            let sha = String(name.prefix { $0 != "." })
            guard !active.contains(sha) else { continue }
            let u = models.partial.appending(path: name)
            r.freedBytes += SpaceAccountant.allocated(u)
            try? fm.removeItem(at: u)
            r.removedParts += 1
        }
        for name in (try? fm.contentsOfDirectory(atPath: models.manifests.path)) ?? [] where name.hasSuffix(".json") {
            if !mark.manifests.contains(String(name.dropLast(5))) { try? fm.removeItem(at: models.manifests.appending(path: name)) }
        }
        return r
    }
}
