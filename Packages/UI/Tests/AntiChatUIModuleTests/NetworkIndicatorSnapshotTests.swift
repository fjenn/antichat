// M2.T03 Definition of done: NetworkIndicator in its three states (net.offline / net.offlineOnly / net.onlineOn) and
// the globe NetworkChip, Light and Dark, on the ResponseActionsSnapshotTests rig; plus the state rule and the
// tooltip text (AT-209 AC4 logic while XCUITest cannot start, Q-015).
// Re-record after an intended visual change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=NetworkIndicatorSnapshotTests.
import AntiChatFoundation
import AntiChatNetwork
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct NetworkIndicatorSnapshotTests {
    func check(_ view: some View, width: CGFloat, name: String) {
        for look in ResponseActionsSnapshotTests.Look.allCases {
            assertSnapshot(of: ResponseActionsSnapshotTests.render(view, width: width, look: look),
                           as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "network")
        }
    }

    @Test func indicatorStates() {
        for (name, mode) in [("offline", NetworkIndicator.Mode.offline), ("offlineOnly", .offlineOnly), ("online", .online)] {
            check(NetworkIndicator(fixed: mode), width: 240, name: "NetworkIndicator.\(name)")
        }
    }

    @Test func chip() {
        check(HStack { NetworkChip(hosts: ["example.org", "127.0.0.1"]); Spacer() }, width: 320, name: "NetworkChip")
    }

    @Test func stateRuleAndTooltip() {
        let p = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        #expect(NetworkIndicator.current(policy: p, path: PathStatus(fake: "ok")) == .online)
        #expect(NetworkIndicator.current(policy: p, path: PathStatus(fake: "none")) == .offline)
        p.offlineOnly = true
        #expect(NetworkIndicator.current(policy: p, path: PathStatus(fake: "none")) == .offlineOnly)
        p.offlineOnly = false
        #expect(NetworkIndicator.tooltip(p.enabledCategories) == "Online: Updates, Model list, Model downloads, Web search, Other")
        #expect(NetworkIndicator.title(.offline).rawValue == "net.offline")
    }
}
}  // extension WindowSuites
