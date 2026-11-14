// Q-015 r3: the DEBUG probe anchor (`probeID` / `probeAnchor`) is now a hidden NSView, so the accessibility hit test
// skips it and reaches the control under the pointer (XCUITest "Not hittable" on reply-card and Settings controls;
// verified end to end by the XCUITests that failed on it: J10SettingsTests, J03EditVersionsTests.testRegenerateVersions).
// An in-process hit test of a concealed background window does not descend into SwiftUI, so this leg checks the other
// half: hidden anchors still report their frames to every probe, nested or not.
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ProbeAnchorHitTestTests {
    @Test func hiddenAnchorsStillReportTheirFrames() throws {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let card = VStack(spacing: 12) {
            Text("A reply card")
            Button("Cancel") {}.accessibilityIdentifier("probeHit.cancel").probeAnchor("probeHit.cancel")
        }
        .padding(40)
        .probeID("probeHit.card")
        let window = NSWindow(contentRect: CGRect(x: 120, y: 120, width: 420, height: 260), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: card)
        BackgroundRun.present(window)
        let end = Date().addingTimeInterval(3)
        while Date() < end, UIProbeRegistry.frame("probeHit.cancel", in: window) == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let button = try #require(UIProbeRegistry.frame("probeHit.cancel", in: window), "the anchor still reports its frame")
        let cardFrame = try #require(UIProbeRegistry.frame("probeHit.card", in: window))
        #expect(cardFrame.contains(button) && button.width > 20 && button.height > 10, "card \(cardFrame) button \(button)")
    }
}
}
