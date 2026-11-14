// AT-294 rollback leg (R-294 AC3; M2.T11 step 5; P-platform-04): the new model's first load fails → automatic flip
// back + `model.updateReverted`; the previous install is intact and loads; the failed model is then collected and
// not offered again. Two failure shapes: the engine rejects the model, and a damaged blob caught by the load gate
// (catalog-upgrade-badsha's shape: a file whose bytes do not match the manifest).
@testable import AntiChatPlatform
import AntiChatStorage
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct UpdateRollbackTests {
    private func flipped(_ tag: String) async throws -> (UpdateFixture, ModelUpdateService) {
        let f = try await UpdateFixture(tag)
        let svc = f.service()
        f.catalog = f.v2
        await svc.catalogRefreshed()
        await svc.settle()
        #expect(try await f.row()?.state == SlotFlip.trialState)
        return (f, svc)
    }

    private func expectReverted(_ f: UpdateFixture, _ svc: ModelUpdateService) async throws {
        let row = try #require(try await f.row())
        #expect(row.catalogEntryID == "starter" && row.state == "ready" && row.previousManifestSHA == nil)
        #expect(await svc.notices.last == ModelUpdateService.Notice("model.updateReverted", ["pack": "chat"]))
        // The previous install is intact and passes the load gate (it loads).
        #expect(Repair.check("starter", models: f.models, full: true).isEmpty)
        if case .failure(let e) = Repair.loadCheck("starter", models: f.models) { Issue.record("previous install refused: \(e)") }
        // The failed model is gone (view + its own blob), shared blobs stay, and it is not offered again.
        #expect(!FileManager.default.fileExists(atPath: f.models.install("starter-v2").path))
        let v2Only = Set(f.v2.models["starter-v2"]!.files.map(\.sha256)).subtracting(f.v1.models["starter"]!.files.map(\.sha256))
        #expect(v2Only.allSatisfy { !BlobStore(models: f.models).contains($0) })
        #expect(await svc.catalogRefreshed().isEmpty)
    }

    @Test func engineRejectsNewModelOnFirstLoad() async throws {
        let (f, svc) = try await flipped("rb-engine")
        await svc.reportLoad(slot: UpdateFixture.slot, ok: false)
        try await expectReverted(f, svc)
    }

    @Test func damagedBlobCaughtByTheLoadGate() async throws {
        let (f, svc) = try await flipped("rb-badsha")
        // Damage the new-only blob (same size, wrong bytes): the load gate's re-hash catches it.
        let sha = f.v2.models["starter-v2"]!.files.first { $0.path == "config.json" }!.sha256
        let blob = BlobStore(models: f.models).url(sha)
        chmod(blob.path, 0o644)
        let h = try FileHandle(forWritingTo: blob)
        try h.write(contentsOf: Data(repeating: 0, count: 64))
        try h.close()
        utimes(blob.path, nil)  // newer than the view's .verified stamp
        let r = await svc.prepareLoad(slot: UpdateFixture.slot)
        guard case .success(let url) = r else { Issue.record("expected the previous install after the revert"); return }
        #expect(url.lastPathComponent == "starter")
        try await expectReverted(f, svc)
    }

    /// M2.T12: the app-side gate addresses models by id (ModelSlot.key): a trial model passes the gate, its failed
    /// first load reverts and hands back the previous model's view; an id no install row holds is untracked.
    @Test func appGateByModelIDRevertsOnFailedFirstLoad() async throws {
        let (f, svc) = try await flipped("rb-gate")
        #expect(await svc.prepareLoad(modelID: "dev-only-model") == .untracked)
        #expect(await svc.prepareLoad(modelID: "starter-v2") == .ready(modelID: "starter-v2", url: f.models.install("starter-v2")))
        let back = await svc.reportLoad(modelID: "starter-v2", ok: false)
        #expect(back?.modelID == "starter")
        #expect(back?.url == f.models.install("starter"))
        try await expectReverted(f, svc)
        #expect(await svc.reportLoad(modelID: "starter", ok: true) == nil)  // not in a trial: no-op
    }

    /// M2 review #2: the cleanup after a revert used to collect every `done` file whose model had no install view yet
    /// (the tier model's file 1 of 2 during setup) — `activeSHA256s` left done jobs out.
    @Test func revertKeepsVerifiedFilesWaitingForTheirInstall() async throws {
        let (f, svc) = try await flipped("rb-keep")
        let other = try DL.makeBlob(in: f.dir, name: "tier-part1.bin", size: 256 * 1024, seed: 21)
        var r = DL.request(other, server: f.server)
        r.modelID = "tier-model"
        let j = await f.dl.enqueue(r)
        #expect(await f.dl.wait(j.id)?.state == .done)
        await svc.reportLoad(slot: UpdateFixture.slot, ok: false)
        try await expectReverted(f, svc)
        #expect(BlobStore(models: f.models).contains(other.sha256), "a verified file of a model not yet installed survives the revert GC")
    }

    /// M2 review #2: an update downloaded and waiting for its pack to go idle (only held in memory) is retained.
    @Test func updateWaitingForIdleIsHeld() async throws {
        let f = try await UpdateFixture("rb-held")
        let svc = f.service()
        f.tracker.begin(.chat)  // a reply streams: the flip waits
        f.catalog = f.v2
        await svc.catalogRefreshed()
        await svc.settle()
        #expect(await svc.phases[UpdateFixture.slot] == .waitingIdle)
        #expect(await svc.heldSHA256s == Set(f.v2.models["starter-v2"]!.files.map(\.sha256)))
        f.tracker.end(.chat)
    }
}
