// AT-211 (R-211 AC1–AC3; M2.T17 step 1): the consent is stored with its date and the terms version (sha256 prefix
// of `onb.3.body` + `onb.3.adult`); a changed version counts as not consented (the sheet shows again); Evil is off on
// a fresh container (EvilDefaultsTests); disable → read-only Evil chats; one action deletes all Evil chats.
import AntiChatFoundation
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("ConsentVersionTests") struct ConsentVersionTests {
    func defaults() -> UserDefaults { UserDefaults.inMemory() }

    @Test func storedWithDateAndVersionAndChangedVersionReasks() throws {
        let db = try AppDatabase.inMemory()
        let v1 = EvilTerms.version(body: "body", adult: "I'm 18")
        #expect(v1.count == 16)
        let d = defaults()
        let m = EvilModeManager(database: db, termsVersion: v1, defaults: d, flagDefaults: d)
        #expect(m.needsConsent)
        #expect(throws: ConsentStore.ConsentError.adultDeclarationMissing) { try m.enable(adultSelfDeclared: false) }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        try m.enable(adultSelfDeclared: true, at: when)
        let rec = try #require(m.consent.record(version: v1))
        #expect(rec.acceptedAt == when)
        #expect(rec.adultSelfDeclared)
        #expect(m.isOn)
        let v2 = EvilTerms.version(body: "body, edited", adult: "I'm 18")
        #expect(v2 != v1)
        let m2 = EvilModeManager(database: db, termsVersion: v2, defaults: d, flagDefaults: d)
        #expect(m2.needsConsent)
        #expect(!m2.isOn, "a new terms version is not consented")
    }

    @Test func evilDefaultsOffOnAFreshContainer() throws {
        let d = defaults()
        let m = EvilModeManager(database: try AppDatabase.inMemory(), termsVersion: "v", defaults: d, flagDefaults: d)
        #expect(!m.isOn)
        #expect(!m.showsSwitch)
        #expect(!m.requiresTouchID)
        #expect(!m.usesMemory)
        #expect(m.defaultModeForNewChat == .normal)
    }

    @Test func hideDisableReadOnlyDeleteAndLastMode() async throws {
        let db = try AppDatabase.inMemory()
        let d = defaults()
        let m = EvilModeManager(database: db, termsVersion: "v", defaults: d, flagDefaults: d)
        try m.enable(adultSelfDeclared: true)
        m.recordLastMode(.evil)
        #expect(m.lastMode == .evil)
        #expect(m.defaultModeForNewChat == .normal, "a new chat starts Normal whatever was used last")
        _ = try ChatRepository(db).create(mode: .evil)
        _ = try ChatRepository(db).create(mode: .evil)
        _ = try ChatRepository(db).create(mode: .normal)
        m.setHidden(true)
        #expect(m.isOn && !m.showsSwitch)
        #expect(m.evilChatCount() == 2, "hide deletes nothing")
        m.setHidden(false)
        m.disable()
        #expect(m.isReadOnly(.evil) && !m.isReadOnly(.normal))
        #expect(try m.deleteAllEvilChats() == 2)
        #expect(m.evilChatCount() == 0)
        #expect(try ChatRepository(db).sidebar().count == 1)
        d.set(false, forKey: "ff.evilMode")
        try m.enable(adultSelfDeclared: true)
        #expect(!m.isOn, "FeatureFlag.evilMode off hides everything")
    }

    @Test func touchIDGatesEvilChatsOnly() async throws {
        struct Fake: EvilAuthenticating { let ok: Bool; func authenticate(reason: String) async -> Bool { ok } }
        let d = defaults()
        let db = try AppDatabase.inMemory()
        let pass = EvilModeManager(database: db, termsVersion: "v", defaults: d, auth: Fake(ok: true), flagDefaults: d)
        let fail = EvilModeManager(database: db, termsVersion: "v", defaults: d, auth: Fake(ok: false), flagDefaults: d)
        #expect(await fail.mayOpen(mode: .evil, reason: "r"), "off: no prompt")
        pass.setTouchID(true)
        #expect(await pass.mayOpen(mode: .evil, reason: "r"))
        #expect(!(await fail.mayOpen(mode: .evil, reason: "r")), "cancel → chat not shown")
        #expect(await fail.mayOpen(mode: .normal, reason: "r"))
    }
}
