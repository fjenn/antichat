// M9.T05 (NFR-U2 / U11): the sidebar's chat rows compare by value (`SidebarChatRow`). Opening a chat, a reply's
// spinner, a rename or a pending delete re-evaluates the rows whose look changes, and those rows do change; the other
// rows are not re-evaluated (before, every row read the window state itself and all of them were rebuilt and
// reconfigured by the List on every chat open and every send).
//   make test-unit FILTER=SidebarRowWorkTests
import AntiChatHarness
import Foundation
import SwiftUI
import Testing
@testable import AntiChatUI

@MainActor @Observable final class SidebarBusy {
    var ids: Set<String> = []
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct SidebarRowWorkTests {
    @Test func onlyTheRowsWhoseStateChangedAreReEvaluated() async throws {
        let service = try ChatListService.inMemory()
        var ids: [String] = []
        for i in 0..<12 { ids.append(try service.create(title: "Chat \(i)").id) }
        let state = WindowState(service: service, enabledPacks: [.chat], seed: 4)
        let busy = SidebarBusy()
        state.rowActivity = { busy.ids.contains($0) ? .streaming : .idle }
        state.activate()
        for _ in 0..<200 where state.sidebar.count < 12 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.sidebar.count == 12)
        let h = RendererRig.Host(SidebarView(state: state, onSearch: {}).frame(width: 260, height: 900), look: .light)
        func pass() async {
            for _ in 0..<3 {
                try? await Task.sleep(for: .milliseconds(20))
                h.host.layoutSubtreeIfNeeded()
                h.host.displayIfNeeded()
            }
        }
        await pass()
        let shown = Set(SidebarChatRow.evaluated).intersection(ids)
        #expect(shown.count >= 6, "the sidebar drew \(shown.count) chat rows")

        // Open a chat: the newly selected row (and only rows whose state changed).
        let a = ids[3], b = ids[7]
        SidebarChatRow.evaluated = []
        state.open(.chat(a))
        await pass()
        var seen = Set(SidebarChatRow.evaluated).intersection(ids)
        #expect(seen.contains(a), "the selected row was not updated")
        #expect(seen.isSubset(of: [a]), "opening a chat re-evaluated \(seen.subtracting([a]).count) other rows")
        #expect(SidebarChatRow.Marks(state).selected == a)

        // Another chat: the old and the new selection.
        SidebarChatRow.evaluated = []
        state.open(.chat(b))
        await pass()
        seen = Set(SidebarChatRow.evaluated).intersection(ids)
        #expect(seen.contains(a) && seen.contains(b), "selection rows not both updated: \(seen)")
        #expect(seen.isSubset(of: [a, b]), "re-evaluated \(seen.subtracting([a, b]).count) other rows")

        // The reply spinner (rowActivity) follows its observable source.
        SidebarChatRow.evaluated = []
        busy.ids = [ids[5]]
        await pass()
        seen = Set(SidebarChatRow.evaluated).intersection(ids)
        #expect(seen == [ids[5]], "spinner: \(seen)")
        #expect(SidebarChatRow.Marks(state).streaming == [ids[5]])

        // Rename and the row's pending delete.
        SidebarChatRow.evaluated = []
        state.renamingChatID = ids[1]
        await pass()
        seen = Set(SidebarChatRow.evaluated).intersection(ids)
        #expect(seen == [ids[1]], "rename: \(seen)")
        state.renamingChatID = nil
        await pass()
        SidebarChatRow.evaluated = []
        state.pendingDelete = .init(ids: [ids[2]], title: "Chat 2", anchor: .row)
        await pass()
        seen = Set(SidebarChatRow.evaluated).intersection(ids)
        #expect(seen == [ids[2]], "delete: \(seen)")
        #expect(SidebarChatRow.Marks(state).deleting == ids[2])
        // A toolbar or multi-row delete marks no row.
        state.pendingDelete = .init(ids: [ids[2]], title: "Chat 2", anchor: .toolbar)
        #expect(SidebarChatRow.Marks(state).deleting == nil)
        state.pendingDelete = .init(ids: [ids[2], ids[4]], title: "2 chats", anchor: .row)
        #expect(SidebarChatRow.Marks(state).deleting == nil)
    }
}
}
