// AT-293 — M2.T10: mark-and-sweep GC keeps every blob an install, a slot's current or previous manifest, or a queued
// download needs, and removes the rest (no reference counts).
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct GCTests {
    @Test func sweepKeepsReferencedRemovesOrphans() async throws {
        let f = try StoreFixture("gc")
        let db = try AppDatabase.inMemory()
        try await f.install(["norm", "evil"], db: db)
        let gc = GarbageCollector(models: f.models, database: db)
        #expect(try gc.sweep().removedBlobs.isEmpty)
        // Remove Evil's view and its slot: its gguf goes, the shared tokenizer stays.
        try InstallView.remove("evil", models: f.models)
        try await db.write { _ = try ModelInstallRecord.deleteOne($0, key: "chat/evil/chat") }
        let orphanPart = f.models.part(String(repeating: "d", count: 64))
        try Data("x".utf8).write(to: orphanPart)
        let activeSHA = String(repeating: "e", count: 64)
        try Data("y".utf8).write(to: f.models.part(activeSHA))
        let r = try gc.sweep(active: [activeSHA])
        #expect(r.removedBlobs == [f.blobs["evil.gguf"]!.sha256])
        #expect(BlobStore(models: f.models).contains(f.blobs["tokenizer.json"]!.sha256))
        #expect(!FileManager.default.fileExists(atPath: orphanPart.path))
        #expect(FileManager.default.fileExists(atPath: f.models.part(activeSHA).path))
        ATLog.write("AT-293", "unit.log", "GC: removing Evil frees its gguf only; shared tokenizer kept; orphan part swept; active download part kept")
    }

    @Test func previousManifestKeptForRollback() async throws {
        let f = try StoreFixture("gc-rb")
        let db = try AppDatabase.inMemory()
        try await f.install(["evil"], db: db)
        // The slot moves on to "norm"; Evil's manifest stays the rollback target and its blobs survive GC (not --all).
        try await f.install(["norm"], db: db)
        try await db.write { d in
            let normSHA = try ModelInstallRecord.fetchOne(d, key: "chat/norm/chat")!.manifestSHA
            let evilSHA = try ModelInstallRecord.fetchOne(d, key: "chat/evil/chat")!.manifestSHA
            try ModelInstallRecord.deleteAll(d)
            try ModelInstallRecord(slot: "chat/normal/chat", catalogEntryID: "norm", manifestSHA: normSHA, state: "ready", previousManifestSHA: evilSHA).insert(d)
        }
        try InstallView.remove("evil", models: f.models)
        let gc = GarbageCollector(models: f.models, database: db)
        #expect(try gc.sweep().removedBlobs.isEmpty)
        #expect(try gc.sweep(all: true).removedBlobs == [f.blobs["evil.gguf"]!.sha256])
    }

    // Release review: a view's symlinks are GC roots on their own. Before the fix, a view whose manifest.json was gone
    // (or no longer decoded) and whose slot row was gone had every blob collected, leaving dangling links.
    @Test(arguments: ["missing", "undecodable"])
    func viewLinksKeepBlobsWithoutManifestOrSlot(_ damage: String) async throws {
        let f = try StoreFixture("gc-links-\(damage)")
        let db = try AppDatabase.inMemory()
        try await f.install(["norm", "evil"], db: db)
        let mf = f.models.install("norm").appending(path: "manifest.json")
        if damage == "missing" { try FileManager.default.removeItem(at: mf) } else { try Data(#"{"model_id":"norm","v":99}"#.utf8).write(to: mf) }
        try await db.write { _ = try ModelInstallRecord.deleteAll($0) }
        // The content-addressed copies go too, so nothing but the view's links names norm's blobs.
        for name in try FileManager.default.contentsOfDirectory(atPath: f.models.manifests.path) {
            try FileManager.default.removeItem(at: f.models.manifests.appending(path: name))
        }
        let gc = GarbageCollector(models: f.models, database: db)
        let normBlobs = Set(f.catalog.models["norm"]!.files.map(\.sha256))
        #expect(normBlobs.isSubset(of: try gc.marked().blobs))
        for all in [false, true] {
            let r = try gc.sweep(all: all)
            #expect(r.removedBlobs.isEmpty, "all=\(all): \(r.removedBlobs)")
        }
        for sha in normBlobs { #expect(BlobStore(models: f.models).contains(sha)) }
        for file in f.catalog.models["norm"]!.files {
            #expect(FileManager.default.fileExists(atPath: f.models.install("norm").appending(path: file.path).path), "link resolves: \(file.path)")
        }
        // Removing the view (the one way models are deleted) still frees its unshared blobs.
        try InstallView.remove("norm", models: f.models)
        let r = try gc.sweep()
        #expect(Set(r.removedBlobs) == normBlobs.subtracting(f.catalog.models["evil"]!.files.map(\.sha256)))
    }

    @Test func stagingLinksAreRoots() async throws {
        let f = try StoreFixture("gc-staging")
        try await f.install(["norm"])
        let sha = f.blobs["model.safetensors"]!.sha256
        try InstallView.remove("norm", models: f.models)
        let tmp = f.models.staging.appending(path: "norm.tmp", directoryHint: .isDirectory)
        try FilePlacement.symlink.place(BlobStore(models: f.models).url(sha), at: tmp.appending(path: "model.safetensors"))
        let r = try GarbageCollector(models: f.models, database: nil).sweep()
        #expect(!r.removedBlobs.contains(sha))
        #expect(BlobStore(models: f.models).contains(sha))
    }

    @Test func rematerializeSwapsAtomically() async throws {
        let f = try StoreFixture("gc-swap")
        try await f.install(["norm"])
        let m = f.catalog.models["norm"]!
        try InstallView.materialize(m, catalogVersion: f.catalog.catalogVersion + 1, models: f.models)
        let mf = try #require(InstallManifest.load(f.models.install("norm").appending(path: "manifest.json")))
        #expect(mf.catalogVersion == f.catalog.catalogVersion + 1)
        #expect(Repair.check("norm", models: f.models).isEmpty)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: f.models.staging.path)) ?? []
        #expect(left.isEmpty, "\(left)")
    }
}
