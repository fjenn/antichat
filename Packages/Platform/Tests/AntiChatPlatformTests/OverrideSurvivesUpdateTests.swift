// AT-222 part 2 (R-222 AC2–AC3; M2.T07): Advanced overrides are `{pack, mode, model_id}` rows that survive a catalog
// version bump and an app update (the database reopened), a revoked override falls back to the recommended model
// with `model.revoked`, and "Reset to recommended" deletes the pack's overrides. The picker shows Fits / Tight /
// Too large per the FitRule, Too large disabled unless allow-over-budget is on.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite struct OverrideSurvivesUpdateTests {
    let t1 = try! SelectorFixtures.profile("t1-m2-16")

    private func select(_ catalog: ModelCatalog, _ store: ModelOverrideStore, allowOver: Bool = false) -> (Selection, ModelOverrideStore.Resolved) {
        let r = ModelOverrideStore.resolve(store.all(), catalog: catalog)
        return (ModelSelector(catalog: catalog).select(profile: t1, modes: [.normal, .evil], overrides: r.overrides, allowOverBudget: allowOver), r)
    }

    @Test func overrideSurvivesCatalogVersionBumpAndAppUpdate() throws {
        let dir = CatalogFixtures.tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appending(path: "antichat.sqlite")
        try ModelOverrideStore(database: AppDatabase.onDisk(at: dbURL)).set(.chat, .normal, modelID: "chat-4b")

        let v100 = try CatalogFixtures.catalog("catalog-valid")
        let v110 = try CatalogFixtures.catalog("catalog-upgrade")
        #expect(v110.catalogVersion > v100.catalogVersion)
        // "App update": a fresh process opens the same database (migrations run, rows stay).
        let reopened = ModelOverrideStore(database: try AppDatabase.onDisk(at: dbURL))
        #expect(reopened.all() == [ModelOverride(pack: .chat, mode: .normal, modelID: "chat-4b")])
        for c in [v100, v110] {
            let (sel, r) = select(c, reopened)
            #expect(r.fellBack.isEmpty)
            let chat = try #require(sel.slot(.chat, .normal, role: "chat"))
            #expect(chat.modelID == "chat-4b")
            #expect(chat.notes.contains(.overrideUsed))
        }
    }

    @Test func revokedOverrideFallsBackToRecommendedWithNotice() throws {
        let store = ModelOverrideStore(database: try AppDatabase.inMemory())
        try store.set(.chat, .normal, modelID: "chat-9b-q4")  // `disable`-revoked in catalog-revoked
        let revoked = try CatalogFixtures.catalog("catalog-revoked")
        let (sel, r) = select(revoked, store)
        #expect(r.fellBack == [ModelOverride(pack: .chat, mode: .normal, modelID: "chat-9b-q4")])
        let chat = try #require(sel.slot(.chat, .normal, role: "chat"))
        #expect(chat.modelID != "chat-9b-q4")
        #expect(chat.modelID != nil)
        #expect(!chat.notes.contains(.overrideUsed))
        // The row stays: a later catalog that lifts the revocation brings the choice back.
        #expect(store.all().count == 1)
        let (again, _) = select(try CatalogFixtures.catalog("catalog-valid"), store)
        #expect(again.slot(.chat, .normal, role: "chat")?.modelID == "chat-9b-q4")
    }

    @Test func resetToRecommendedDeletesThePacksOverrides() throws {
        let store = ModelOverrideStore(database: try AppDatabase.inMemory())
        try store.set(.chat, .normal, modelID: "chat-4b")
        try store.set(.chat, .evil, modelID: "evil-4b")
        try store.set(.photo, .normal, modelID: "img-klein-q8")
        try store.reset(.chat)
        #expect(store.all() == [ModelOverride(pack: .photo, mode: .normal, modelID: "img-klein-q8")])
        let (sel, _) = select(try CatalogFixtures.catalog("catalog-valid"), store)
        let recommended = ModelSelector(catalog: try CatalogFixtures.catalog("catalog-valid")).select(profile: t1, modes: [.normal, .evil])
        #expect(sel.slot(.chat, .normal, role: "chat") == recommended.slot(.chat, .normal, role: "chat"))
        try store.set(.photo, .normal, modelID: nil)
        #expect(store.all().isEmpty)
    }

    @Test func pickerFitPillsOnT1() throws {
        let c = try CatalogFixtures.catalog("catalog-valid")
        let sel = ModelSelector(catalog: c).select(profile: t1, modes: [.normal, .evil])
        let opts = ModelOverrideStore.options(pack: .chat, mode: .normal, selection: sel, catalog: c, profile: t1, allowOverBudget: false)
        #expect(opts.first?.recommended == true)
        #expect(opts.first(where: { $0.modelID == "chat-4b" })?.fit == .fits)
        let big = try #require(opts.first { $0.modelID == "chat-35b-q4" })
        #expect(big.fit == .tooLarge)
        #expect(big.disabled)
        #expect(!opts.contains { $0.modelID.hasPrefix("evil-") })
        let over = ModelOverrideStore.options(pack: .chat, mode: .normal, selection: sel, catalog: c, profile: t1, allowOverBudget: true)
        #expect(over.first { $0.modelID == "chat-35b-q4" }?.disabled == false)
        // Evil never offers the starter and lists the Evil entries.
        let evil = ModelOverrideStore.options(pack: .chat, mode: .evil, selection: sel, catalog: c, profile: t1, allowOverBudget: false)
        #expect(!evil.contains { $0.modelID == sel.chatFast?.modelID })
        #expect(evil.allSatisfy { $0.modelID.hasPrefix("evil-") })
        // The Too-large choice is honoured only with allow-over-budget (NFR-R5).
        let store = ModelOverrideStore(database: try AppDatabase.inMemory())
        try store.set(.chat, .normal, modelID: "chat-35b-q4")
        #expect(select(c, store).0.slot(.chat, .normal, role: "chat")?.modelID != "chat-35b-q4")
        #expect(select(c, store, allowOver: true).0.slot(.chat, .normal, role: "chat")?.modelID == "chat-35b-q4")
        // Info columns (R-222 AC2): quant and context per row.
        #expect(opts.first?.quant != nil && opts.first?.ctx != nil)
    }
}
