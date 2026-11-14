// M8.T03 definition of done: MemoryNotice states — proposed (suggestion card, Save / Dismiss), saved (topic chip +
// text + Undo), undone ("Undone"), the "Used memory ▸" line expanded, and the sidebar review pill — in Light, Dark and
// Evil (Dark inside the Evil frame). Same rig as StatusPillSnapshotTests.
// Re-record after an intended visual change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=MemoryNoticeSnapshotTests.
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct MemoryNoticeSnapshotTests {
    enum Look: String, CaseIterable { case light, dark, evil }

    func check(_ view: some View, width: CGFloat, name: String) {
        for look in Look.allCases {
            let rig: ResponseActionsSnapshotTests.Look = look == .light ? .light : .dark
            let image = ResponseActionsSnapshotTests.render(view.padding(Spacing.space2).evilFrame(look == .evil),
                                                            width: width, look: rig)
            assertSnapshot(of: image, as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "memoryNotice")
        }
    }

    static let food = MemoryNotice.Row(id: "e1", topic: "Food", text: "Vegetarian", undone: false)

    @Test func states() {
        check(MemorySuggestionCard(id: "s1", text: "Plays jazz piano", onDismiss: {}, onSave: {}), width: 460, name: "proposed")
        check(MemoryNoticeView(rows: [Self.food]), width: 420, name: "saved")
        check(MemoryNoticeView(rows: [MemoryNotice.Row(id: "e1", topic: "Food", text: "Vegetarian", undone: true)]),
              width: 420, name: "undone")
        check(MemoryReadLine(rows: [Self.food, MemoryNotice.Row(id: "i2", topic: "Work", text: "Night nurse", undone: false)],
                             expanded: true), width: 420, name: "usedMemory")
        check(MemoryReviewPill(fixed: 3), width: 240, name: "reviewPill")
        #expect(CopyKey("act.memoryRead").string() == "Used memory")
        #expect(CopyText(CopyKey("memory.propose"), ["fact": "Plays jazz piano"]).string.contains("Plays jazz piano"))
    }
}
}  // extension WindowSuites
