// M3.T02 step 5: PermissionPromptSheet (S-24, `voice.permission`) and PermissionDeniedPopover (denied →
// `voice.denied`, no device → `voice.noDevice`), light and dark. Evil / Incognito change only the window frame
// around them (WindowSnapshotTests), not these views. Re-record after an intended visual change:
// SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=PermissionSnapshotTests.
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct PermissionSnapshotTests {
    func check(_ view: some View, width: CGFloat, name: String) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: width, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "permission")
        }
    }

    @Test func promptSheet() {
        check(PermissionPromptSheet(onContinue: {}, onCancel: {}), width: 340, name: "PermissionPromptSheet")
    }

    @Test func deniedAndNoDevicePopover() {
        check(PermissionDeniedPopover(reason: .denied, openSettings: {}), width: 260, name: "PermissionDenied")
        check(PermissionDeniedPopover(reason: .noDevice, openSettings: {}), width: 260, name: "PermissionNoDevice")
    }
}
}  // extension WindowSuites
