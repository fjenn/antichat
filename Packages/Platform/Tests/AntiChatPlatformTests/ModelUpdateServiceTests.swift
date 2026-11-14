// AT-294 (R-294 AC1–AC4, R-220 AC2; M2.T11): automatic, silent model updates by default; > 2 GB or auto-update off
// asks ([Update] [Later]); nothing downloads on an expensive or constrained path; the flip waits for idle and shows
// `model.upgraded`. Diff + policy against the signed fixture catalogs (catalog-upgrade, -big, -badsha); download
// and flip against a two-version local catalog served by range-server.py.
@testable import AntiChatPlatform
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct ModelUpdateServiceTests {
    static let installed = [ModelInstallRecord(slot: "chat/normal/chat_fast", catalogEntryID: "chat-0.8b", manifestSHA: "x", state: "ready")]

    @Test func fixtureCatalogsProduceTheCandidateAndPolicy() throws {
        let up = try CatalogFixtures.catalog("catalog-upgrade")
        let c = try #require(UpdatePolicy.candidates(installed: Self.installed, catalog: up, present: []).first)
        #expect(c.from == "chat-0.8b" && c.to == "chat-0.8b-v2" && c.reason == .supersedes && c.pack == .chat)
        // Shared blobs already in the store cost nothing: only the changed files count.
        let shared = Set(up.models["chat-0.8b"]!.files.map(\.sha256))
        let extra = UpdatePolicy.candidates(installed: Self.installed, catalog: up, present: shared).first!.extraBytes
        #expect(extra > 0 && extra < c.extraBytes)
        #expect(UpdatePolicy.decide(c, autoUpdate: true, path: .ok, free: 500_000_000_000) == .auto)
        #expect(UpdatePolicy.decide(c, autoUpdate: false, path: .ok, free: 500_000_000_000) == .ask)
        #expect(UpdatePolicy.decide(c, autoUpdate: true, path: .expensive, free: 500_000_000_000) == .holdNetwork)
        #expect(UpdatePolicy.decide(c, autoUpdate: true, path: .constrained, free: 500_000_000_000) == .holdNetwork)
        #expect(UpdatePolicy.decide(c, autoUpdate: true, path: .ok, free: 10_000_000_000) == .diskShort(gbNeeded: 1))
        let big = try #require(UpdatePolicy.candidates(installed: Self.installed, catalog: try CatalogFixtures.catalog("catalog-upgrade-big"), present: []).first)
        #expect(big.extraBytes > UpdatePolicy.autoLimitBytes)
        #expect(UpdatePolicy.decide(big, autoUpdate: true, path: .ok, free: 10_000_000_000_000) == .ask)
        // No candidate from the catalog the slot was installed from, nor for a rejected (reverted) target.
        #expect(UpdatePolicy.candidates(installed: Self.installed, catalog: try CatalogFixtures.catalog("catalog-valid"), present: []).isEmpty)
        #expect(UpdatePolicy.candidates(installed: Self.installed, catalog: up, present: [], rejected: ["chat-0.8b-v2"]).isEmpty)
    }

    @Test func silentBackgroundDownloadThenFlipWhenIdleWithNotice() async throws {
        let f = try await UpdateFixture("upd-auto")
        let svc = f.service()
        f.catalog = f.v2
        let found = await svc.catalogRefreshed()
        await svc.settle()
        #expect(found.map(\.to) == ["starter-v2"])
        #expect(found.first!.extraBytes == 96 * 1024)  // only the new config: tokenizer + weights are shared
        #expect(await svc.offers.isEmpty)
        let row = try #require(try await f.row())
        #expect(row.catalogEntryID == "starter-v2" && row.state == SlotFlip.trialState)
        #expect(row.previousManifestSHA != nil)
        #expect(await svc.notices == [ModelUpdateService.Notice("model.upgraded", ["pack": "chat"])])
        #expect(f.v2Requests >= 1)
        // Downloaded at the lowest queue priority.
        #expect(await f.dl.allJobs.contains { $0.request.priority == ModelUpdateService.backgroundPriority })
        // The first successful load ends the trial; the old view goes, its manifest stays for `models rollback`.
        await svc.reportLoad(slot: UpdateFixture.slot, ok: true)
        let done = try #require(try await f.row())
        #expect(done.state == "ready" && done.previousManifestSHA == row.previousManifestSHA)
        #expect(!FileManager.default.fileExists(atPath: f.models.install("starter").path))
        #expect(Repair.check("starter-v2", models: f.models).isEmpty)
    }

    @Test(arguments: [PathStatus.State.expensive, .constrained])
    func meteredPathDownloadsNothing(_ path: PathStatus.State) async throws {
        let f = try await UpdateFixture("upd-\(path.rawValue)")
        let svc = f.service(path: path)
        f.catalog = f.v2
        #expect(await svc.catalogRefreshed().count == 1)
        #expect(await svc.phases[UpdateFixture.slot] == .held)
        #expect(f.v2Requests == 0)
        #expect(try await f.row()?.catalogEntryID == "starter")
    }

    @Test func autoUpdateOffShowsTheOfferRowAndLaterHidesIt() async throws {
        let f = try await UpdateFixture("upd-ask")
        let svc = f.service(autoUpdate: false)
        f.catalog = f.v2
        await svc.catalogRefreshed()
        await svc.settle()
        #expect(await svc.offers.map(\.to) == ["starter-v2"])
        #expect(f.v2Requests == 0)
        await svc.later(slot: UpdateFixture.slot)
        #expect(await svc.offers.isEmpty)
        await svc.catalogRefreshed()
        await svc.settle()
        #expect(await svc.offers.isEmpty, "Later hides the offer until the next catalog version")
        // [Update] downloads and flips.
        let svc2 = f.service(autoUpdate: false)
        await svc2.catalogRefreshed()
        await svc2.settle()
        await svc2.accept(slot: UpdateFixture.slot)
        await svc2.settle()
        #expect(try await f.row()?.catalogEntryID == "starter-v2")
    }

    @Test func featureFlagOffDisablesTheService() async throws {
        let f = try await UpdateFixture("upd-flag")
        let svc = ModelUpdateService(models: f.models, database: f.db, catalog: { f.v2 }, activity: f.tracker, autoUpdate: { true },
                                     path: { .ok }, freeBytes: { 500_000_000_000 }, coordinator: f.dl, enabled: { false })
        #expect(await svc.catalogRefreshed().isEmpty)
        #expect(try await f.row()?.catalogEntryID == "starter")
        #expect(FeatureFlag.autoModelUpdates.isEnabled(UserDefaults.inMemory()))
    }

    @Test func revocationSwitchesToTheReplacementWithNotice() async throws {
        let f = try await UpdateFixture("upd-revoke", v2Supersedes: false)
        var r = f.v2
        r.revoked = [CatalogRevocation(id: "starter", action: .disable, reason: "takedown")]
        let revoked = r
        f.catalog = revoked
        let svc = ModelUpdateService(models: f.models, database: f.db, catalog: { revoked }, activity: f.tracker, autoUpdate: { false },
                                     path: { .ok }, freeBytes: { 500_000_000_000 }, coordinator: f.dl, replacement: { _ in "starter-v2" },
                                     enabled: { true })
        let c = await svc.catalogRefreshed()
        await svc.settle()
        #expect(c.first?.reason == .revoked)
        #expect(try await f.row()?.catalogEntryID == "starter-v2", "a revocation switches even with auto-update off")
        #expect(await svc.notices.first == ModelUpdateService.Notice("model.revoked", ["model": "starter", "replacement": "starter-v2"]))
    }

    /// M2 review #3: two overlapping refreshes (launch + the first catalog refresh, or a double [Update]) used to flip
    /// the slot twice; the second flip recorded the new model as its own rollback target.
    @Test func overlappingRefreshesFlipOnceAndKeepTheRollbackTarget() async throws {
        let f = try await UpdateFixture("upd-overlap")
        let before = try #require(try await f.row()).manifestSHA
        let svc = f.service()
        f.catalog = f.v2
        async let a = svc.catalogRefreshed()
        async let b = svc.catalogRefreshed()
        _ = await (a, b)
        await svc.settle()
        await svc.launch()
        await svc.settle()
        let row = try #require(try await f.row())
        #expect(row.catalogEntryID == "starter-v2" && row.state == SlotFlip.trialState)
        #expect(row.previousManifestSHA == before, "the rollback target is still the old model")
        #expect(await svc.notices.filter { $0.key == "model.upgraded" }.count == 1)
        // SlotFlip itself is idempotent for the model the row already holds.
        #expect(try SlotFlip.flip(slot: UpdateFixture.slot, to: f.v2.models["starter-v2"]!, catalogVersion: 110, models: f.models,
                                  database: f.db) == false)
        #expect(try await f.row()?.previousManifestSHA == before)
        // The revert then restores the real previous model.
        await svc.reportLoad(slot: UpdateFixture.slot, ok: false)
        #expect(try await f.row()?.catalogEntryID == "starter")
    }

    /// M2 review #4: the refresh does not wait for the download — it returns (offers published) while the update is
    /// still downloading; the flip follows when the child download finishes.
    @Test func refreshReturnsWhileTheUpdateDownloads() async throws {
        let f = try await UpdateFixture("upd-bg")
        final class Gate: @unchecked Sendable {
            let lock = NSLock(); var open = false
            func wait() async { while !lock.withLock({ open }) { try? await Task.sleep(for: .milliseconds(10)) } }
        }
        let gate = Gate()
        let dl = f.dl
        let svc = ModelUpdateService(models: f.models, database: f.db, catalog: { [f] in f.catalog }, activity: f.tracker,
                                     autoUpdate: { true }, path: { .ok }, freeBytes: { 500_000_000_000 },
                                     fetch: { m in await gate.wait(); return await ModelUpdateService.coordinatorFetch(dl, m) },
                                     enabled: { true })
        f.catalog = f.v2
        let found = await svc.catalogRefreshed()
        #expect(found.count == 1)
        #expect(await svc.phases[UpdateFixture.slot] == .downloading)
        #expect(try await f.row()?.catalogEntryID == "starter")
        // A second refresh during the download neither re-starts it nor offers it.
        await svc.catalogRefreshed()
        #expect(await svc.offers.isEmpty)
        gate.lock.withLock { gate.open = true }
        await svc.settle()
        #expect(try await f.row()?.catalogEntryID == "starter-v2")
    }
}
