// M8.T03 AT-060 unit leg (R-060 AC2/AC3/AC4): mode transitions and defaults, typed RESET (exact, case-sensitive),
// edit/delete/add each log one memory_event (delete undoable), Paused keeps items but the tool saves nothing,
// suggestions Save/Dismiss, and the inline line's rows + Undo.
//   make test-unit FILTER=MemoryViewModelTests
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Defaults
import Foundation
import Testing
@testable import AntiChatUI

@MainActor @Suite(.serialized, .isolatedSettings) struct MemoryViewModelTests {
    func model() throws -> (MemorySettingsViewModel, MemoryStore) {
        let db = try AppDatabase.inMemory()
        let m = MemorySettingsViewModel(database: db)
        return (m, m.store)
    }

    @Test func defaultsAreOnSensitiveOffEvilOff() {
        let suite = UserDefaults.inMemory()
        #expect(Defaults.Keys.memoryMode.defaultValue == "on")
        #expect(Defaults.Keys.memoryIncludeSensitive.defaultValue == false)
        #expect(Defaults.Keys.useMemoryInEvil.defaultValue == false)
        #expect(MemoryPolicy.from(suite) == MemoryPolicy(mode: .on, includeSensitive: false, useInEvil: false))
    }

    @Test func browseEditDeleteUndoAndReset() throws {
        let (m, store) = try model()
        try m.add(topic: "Food", text: "Vegetarian")
        try m.add(topic: "food", text: "Likes Thai curry")
        try m.add(topic: "Work", text: "Nurse")
        #expect(m.groups.map(\.name) == ["Food", "Work"] && m.groups[0].entries.count == 2 && m.count == 3)
        let id = m.groups[1].entries[0].item.id
        try m.edit(id, text: "Night nurse")
        try m.delete(id)
        #expect(m.count == 2 && m.lastDeletedEvent != nil)
        try m.undoDelete()
        #expect(m.groups.last?.entries.first?.item.text == "Night nurse")
        #expect(try store.events(itemID: id).map(\.op) == [.add, .update, .delete])
        m.query = "thai"
        #expect(m.count == 1)
        m.query = ""
        #expect(!MemorySettingsViewModel.resetEnabled("RES") && !MemorySettingsViewModel.resetEnabled("reset"))
        try m.reset(typed: "reset")
        #expect(m.count == 3)
        try m.reset(typed: "RESET")
        #expect(m.count == 0)
        #expect(try store.active().isEmpty)
    }

    @Test func pausedKeepsItemsAndSavesNothing() async throws {
        let (m, store) = try model()
        try m.add(topic: "Food", text: "Vegetarian")
        let x = MemoryToolExecutor(store: store, decider: MemoryUpdateDecider(store: store, embedder: nil, model: nil),
                                   policy: { MemoryPolicy(mode: .paused) })
        let r = try await x.run(#"{"action":"save","topic":"Work","value":"Nurse"}"#, chatID: "c")
        #expect(r.contains("memory_paused"))
        #expect(try store.active().count == 1)
    }

    @Test func suggestionsSaveAndDismiss() throws {
        let (m, store) = try model()
        try store.database.write { db in
            for (i, t) in ["Plays jazz piano", "Runs on Sundays"].enumerated() {
                try db.execute(sql: "INSERT INTO memory_suggestion (id, text, topic, created_at) VALUES (?, ?, 'Hobbies', ?)", arguments: ["s\(i)", t, Double(i)])
            }
        }
        m.reload()
        #expect(m.suggestions.count == 2 && m.count == 0)
        try m.saveSuggestion("s0")
        try m.dismissSuggestion("s1")
        #expect(m.suggestions.isEmpty && m.count == 1 && m.groups[0].entries[0].item.origin == .review)
    }

    @Test func inlineNoticeRowsAndUndo() throws {
        let (_, store) = try model()
        let (_, e) = try store.insert(topic: "Food", key: "diet", text: "Vegetarian", origin: .tool)
        let rows = MemoryNotice.rows([e.id], store: store)
        #expect(rows == [MemoryNotice.Row(id: e.id, topic: "Food", text: "Vegetarian", undone: false)])
        try store.undo(eventID: e.id)
        #expect(MemoryNotice.rows([e.id], store: store).first?.undone == true)
        #expect(try store.active().isEmpty)
    }

    @Test func usedMemoryRowsSkipDeletedItems() throws {
        let (_, store) = try model()
        let (a, _) = try store.insert(topic: "Food", key: "diet", text: "Vegetarian", origin: .user)
        let (b, _) = try store.insert(topic: "Work", key: "job", text: "Nurse", origin: .user)
        #expect(MemoryNotice.readRows([a.id, b.id], store: store).map(\.text) == ["Vegetarian", "Nurse"])
        try store.database.write { try $0.execute(sql: "DELETE FROM memory_item WHERE id = ?", arguments: [b.id]) }
        #expect(MemoryNotice.readRows([a.id, b.id], store: store).map(\.topic) == ["Food"])
        #expect(MemoryNotice.readRows([], store: store).isEmpty && MemoryNotice.readRows([a.id], store: nil).isEmpty)
    }

    @Test func reviewPillCountsPendingSuggestions() async throws {
        let (m, store) = try model()
        let pill = MemoryReviewPillModel(database: store.database)
        try store.database.write { db in
            for (i, t) in ["Plays jazz piano", "Runs on Sundays", "Has a cat"].enumerated() {
                try db.execute(sql: "INSERT INTO memory_suggestion (id, text, topic, created_at) VALUES (?, ?, 'Hobbies', ?)", arguments: ["p\(i)", t, Double(i)])
            }
        }
        func settle(_ want: Int) async {
            for _ in 0..<200 where pill.count != want { try? await Task.sleep(for: .milliseconds(10)) }
        }
        await settle(3)
        #expect(pill.count == 3)
        #expect(MemoryReviewPill.title(3)?.string == "3 new things to review" && MemoryReviewPill.title(0) == nil)
        m.reload()
        try m.saveSuggestion("p0")
        try m.dismissSuggestion("p1")
        await settle(1)
        #expect(pill.count == 1)
    }
}
