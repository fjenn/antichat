// M2 review #1 (P0): removing a pack's models (Settings › Capabilities, Evil Mode) used to sweep blind —
// `GarbageCollector(database: nil).sweep()` with no active set deleted in-flight parts, verified files whose model
// had no install view yet and the rollback window. ModelRemoval is the one shared path: evict → delete → GC with the
// real database and the full retained set.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct ModelRemovalTests {
    @Test func removalKeepsOpenJobsVerifiedNotInstalledAndRollbackWindow() async throws {
        let f = try StoreFixture("removal")
        let db = try AppDatabase.inMemory()
        let dl = f.coordinator(db)
        try await f.install(["norm"], db: db, dl: dl)
        // Evil's files are verified but its install view is not written yet (file 1 of 2 case, setup still running;
        // the setup's catalog is not loaded here, so it cannot write the view).
        let evil = f.catalog.models["evil"]!
        for j in await dl.enqueue(model: evil, pack: "chat") { _ = await dl.wait(j.id) }
        let setup = SetupInstaller(coordinator: dl, database: db, catalog: { nil })
        await setup.addEvil([InstallPlan.Item(modelID: "evil", pack: .chat, mode: .evil, role: "chat",
                                              requests: evil.files.map { DownloadRequest(file: $0, model: evil, pack: "chat") })])
        #expect(!FileManager.default.fileExists(atPath: f.models.install("evil").path))
        // An open (failed, retried by the policy) download with a part on disk.
        let openSHA = String(repeating: "e", count: 64)
        let open = await dl.enqueue(DownloadRequest(sha256: openSHA, size: 10, sources: [f.server.url("missing.bin")], modelID: "other"))
        _ = await dl.wait(open.id)
        try Data("partial".utf8).write(to: f.models.part(openSHA))
        final class Box: @unchecked Sendable { var ids: Set<String> = [] }
        let evicted = Box()
        let report = try #require(await ModelRemoval.remove(
            ["norm"], models: f.models, database: db, evict: { evicted.ids = $0 },
            retained: { await ModelRemoval.retained(coordinator: dl, setup: setup, updates: nil, releasing: $0) }))
        #expect(evicted.ids == ["norm"])
        let store = BlobStore(models: f.models)
        // norm's own files go …
        #expect(!store.contains(f.blobs["config.json"]!.sha256))
        #expect(!store.contains(f.blobs["model.safetensors"]!.sha256))
        // … Evil's verified files (shared tokenizer included) and the open part stay.
        #expect(store.contains(f.blobs["evil.gguf"]!.sha256))
        #expect(store.contains(f.blobs["tokenizer.json"]!.sha256))
        #expect(FileManager.default.fileExists(atPath: f.models.part(openSHA).path))
        #expect(report.removedParts == 0)
        // The removed model's slot row is gone with its view.
        #expect(try db.read { try ModelInstallRecord.fetchOne($0, key: "chat/norm/chat") } == nil)

        // The old blind sweep (the code this replaces) would have deleted both: the regression guard.
        let blind = try GarbageCollector(models: f.models, database: nil).marked(active: [])
        #expect(!blind.blobs.contains(f.blobs["evil.gguf"]!.sha256))
    }

    @Test func rollbackWindowSurvivesARemoval() async throws {
        let f = try StoreFixture("removal-rb")
        let db = try AppDatabase.inMemory()
        let dl = f.coordinator(db)
        try await f.install(["evil", "norm"], db: db, dl: dl)
        // Slot chat/normal/chat moved from evil to norm: evil's manifest is the rollback target; evil's view is gone.
        let evilSHA = try await f.rowSHA(db, "chat/evil/chat")
        let normSHA = try await f.rowSHA(db, "chat/norm/chat")
        try db.write { d in
            try ModelInstallRecord.deleteAll(d)
            try ModelInstallRecord(slot: "chat/normal/chat", catalogEntryID: "norm", manifestSHA: normSHA, state: "ready",
                                   previousManifestSHA: evilSHA).insert(d)
        }
        try InstallView.remove("evil", models: f.models)
        // Removing an unrelated model (nothing installed under that id) still sweeps: evil's blobs must stay.
        await ModelRemoval.remove(["photo-x"], models: f.models, database: db, evict: { _ in },
                                  retained: { await dl.retainedSHA256s(releasing: $0) })
        #expect(BlobStore(models: f.models).contains(f.blobs["evil.gguf"]!.sha256))
    }

    @Test func releasingFreesTheRemovedPacksPartialModels() async throws {
        let f = try StoreFixture("removal-rel")
        let db = try AppDatabase.inMemory()
        let dl = f.coordinator(db)
        try await f.install(["norm"], db: db, dl: dl)
        for j in await dl.enqueue(model: f.catalog.models["evil"]!, pack: "chat") { _ = await dl.wait(j.id) }
        // The pack owning "evil" is removed before evil was installed: its verified files go, norm's stay.
        await ModelRemoval.remove([], releasing: ["evil"], models: f.models, database: db, evict: { _ in },
                                  retained: { await dl.retainedSHA256s(releasing: $0) })
        let store = BlobStore(models: f.models)
        #expect(!store.contains(f.blobs["evil.gguf"]!.sha256))
        #expect(store.contains(f.blobs["tokenizer.json"]!.sha256))  // shared with the installed norm
        #expect(store.contains(f.blobs["config.json"]!.sha256))
    }
}

extension StoreFixture {
    func rowSHA(_ db: AppDatabase, _ slot: String) async throws -> String {
        try #require(try db.read { try ModelInstallRecord.fetchOne($0, key: slot) }).manifestSHA
    }
}
