// M2.T07 DoD: FitPill's three states (Fits / Tight / Too large) and a ModelOverrideRow, light and dark (vq-10 §
// Capabilities › Advanced). Re-record after an intended visual change:
// SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=FitPillSnapshotTests.
import AntiChatPlatform
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct FitPillSnapshotTests {
    func check(_ view: some View, width: CGFloat, name: String) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: width, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "fitpill")
        }
    }

    @Test func threeStates() {
        check(HStack { FitPill(fit: .fits); FitPill(fit: .tight); FitPill(fit: .tooLarge); Spacer() }, width: 260, name: "FitPill")
        #expect(FitPill.key(.fits) == "set.cap.fit.fits")
        #expect(FitPill.key(.tooLarge) == "set.cap.fit.tooLarge")
    }

    @Test func overrideRowInfoLine() {
        let slot = SelectionSlot(pack: .chat, mode: .normal, role: "chat", modelID: "chat-9b-q4", installIDs: ["chat-9b-q4"], ctx: 16384,
                                 fit: .fits, reason: nil, notes: [], keepInternal: false)
        let opts = [ModelOverrideStore.Option(modelID: "chat-9b-q4", quant: "4bit", ctx: 16384, fit: .fits, recommended: true, disabled: false),
                    ModelOverrideStore.Option(modelID: "chat-35b-q4", quant: "4bit", ctx: 8192, fit: .tooLarge, recommended: false, disabled: true)]
        check(ModelOverrideRow(pack: .chat, mode: .normal, current: slot, options: opts, overridden: nil, onPick: { _ in }).padding(8),
              width: 520, name: "ModelOverrideRow")
        #expect(ModelOverrideRow.tokens(16384) == "16K")
    }
}
}  // extension WindowSuites
