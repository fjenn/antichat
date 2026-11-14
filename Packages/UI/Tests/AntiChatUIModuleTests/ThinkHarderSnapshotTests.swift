// M1.T15 Definition of done: snapshots of the ThinkHarderToggle (off / on / unavailable = the model has no thinking
// mode, preset tooltip) and the ReasoningDisclosure (streaming "Thinking… 3 s" / collapsed "Thought for 12 s ▸" /
// expanded with the dimmed reasoning), Light and Dark, on the ResponseActionsSnapshotTests rig.
// Re-record after an intended visual change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ThinkHarderSnapshotTests.
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ThinkHarderSnapshotTests {
    func check(_ view: some View, width: CGFloat, name: String) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: width, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "thinkHarder")
        }
    }

    static let reasoning = "The user asks for the answer. Recall the guide: the answer is 42. Check the units, then say it plainly."

    @Test func toggleStates() {
        for (name, on, preset) in [("off", false, false), ("on", true, false), ("unavailable", false, true)] {
            check(HStack { ThinkHarderToggle(isOn: .constant(on), preset: preset); Spacer() }, width: 80,
                  name: "ThinkHarderToggle.\(name)")
        }
        #expect(ThinkHarderToggle.tooltipKey(preset: true) == "think.tip.preset")
        #expect(ThinkHarderToggle.tooltipKey(preset: false) == "tip.think")
    }

    @Test func disclosureStates() {
        check(ReasoningDisclosure(reasoning: Self.reasoning, thinking: true, sentAt: Date().addingTimeInterval(-3.4),
                                  thoughtSeconds: nil),
              width: 560, name: "ReasoningDisclosure.streaming")
        check(ReasoningDisclosure(reasoning: Self.reasoning, thinking: false, sentAt: nil, thoughtSeconds: 12.2),
              width: 560, name: "ReasoningDisclosure.collapsed")
        check(ReasoningDisclosure(reasoning: Self.reasoning, thinking: false, sentAt: nil, thoughtSeconds: 12.2,
                                  expanded: true),
              width: 560, name: "ReasoningDisclosure.expanded")
    }
}
}  // extension WindowSuites
