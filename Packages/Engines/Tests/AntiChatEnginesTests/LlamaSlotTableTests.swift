// M1.T20 (A-M1-T14a (e) deferred here): llama-server slot assignment with KV save/restore for non-incognito chats
// only (IncognitoGuards guard 5: an incognito session's KV is never written to `--slot-save-path`).
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct LlamaSlotTableTests {
    let a = UUID(), b = UUID(), c = UUID(), inc = UUID()

    @Test func aChatKeepsItsSlotWithoutActions() {
        var t = LlamaSlotTable(slots: 2, persistence: true)
        #expect(t.assign(a, incognito: false) == (0, []))
        #expect(t.assign(b, incognito: false) == (1, []))
        #expect(t.assign(a, incognito: false) == (0, []))
    }

    @Test func evictionSavesAndReturnRestores() {
        var t = LlamaSlotTable(slots: 1, persistence: true)
        _ = t.assign(a, incognito: false)
        let toB = t.assign(b, incognito: false)
        #expect(toB.slot == 0 && toB.actions == [.save(slot: 0, session: a)])
        let backToA = t.assign(a, incognito: false)
        #expect(backToA.actions == [.save(slot: 0, session: b), .restore(slot: 0, session: a)])
    }

    @Test func incognitoIsNeverSavedOrRestored() {
        var t = LlamaSlotTable(slots: 1, persistence: true)
        _ = t.assign(inc, incognito: true)
        // Another chat takes the slot: the incognito KV is overwritten, never saved.
        #expect(t.assign(a, incognito: false).actions.isEmpty)
        // The incognito chat comes back: a's KV is saved, nothing is restored for it.
        #expect(t.assign(inc, incognito: true).actions == [.save(slot: 0, session: a)])
        #expect(!t.saved.contains(inc))
    }

    @Test func noPersistenceNoActions() {
        var t = LlamaSlotTable(slots: 1, persistence: false)
        _ = t.assign(a, incognito: false)
        #expect(t.assign(b, incognito: false).actions.isEmpty)
        #expect(t.assign(a, incognito: false).actions.isEmpty)
    }

    @Test func failedSaveIsNotRestored() {
        var t = LlamaSlotTable(slots: 1, persistence: true)
        _ = t.assign(a, incognito: false)
        _ = t.assign(b, incognito: false)
        t.saveFailed(a)
        #expect(t.assign(a, incognito: false).actions == [.save(slot: 0, session: b)])
        _ = c
    }

    @Test func fileNamesHaveNoPathSeparators() {
        let n = LlamaSlotTable.fileName(session: a, modelTag: "../evil/9b q4-32768")
        #expect(!n.contains("/") && !n.contains(" ") && !n.contains(".."))
        #expect(n.hasSuffix("\(a.uuidString.lowercased()).bin"))
    }
}
