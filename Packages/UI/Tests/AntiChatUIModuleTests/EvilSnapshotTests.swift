// EvilSnapshotTests (M2.T17 Definition of done): every ModeSwitch (Normal, Evil, locked), EvilBadge and
// EvilSettingsPanel state (disabled, enabled, hidden, Touch ID on) plus the lock popover and the enable sheet, in Light
// and Dark. Same rig as ComposerSnapshotTests. Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=EvilSnapshotTests.
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct EvilSnapshotTests {
    typealias Look = ComposerSnapshotTests.Look

    static func render(_ view: some View, look: Look, width: CGFloat? = nil) -> NSImage {
        DesignBundle.forceBrandAccent = true
        let root = view
            .frame(width: width)
            .padding(Spacing.space4)
            .background(Color.surfaceCanvas)
            .environment(\.reduceMotionOverride, true)
            .environment(\.colorScheme, look == .light ? .light : .dark)
        let host = NSHostingView(rootView: root)
        host.appearance = look.appearance
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = look.appearance
        window.contentView = host
        for _ in 0..<2 {
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let size = host.frame.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded()),
                                   pixelsHigh: Int((size.height * 2).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        look.appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func panelModel(_ setup: (EvilModeManager) throws -> Void) throws -> EvilModeModel {
        let d = UserDefaults.inMemory()
        let m = EvilModeManager(database: try AppDatabase.inMemory(), termsVersion: "v", defaults: d, flagDefaults: d)
        try setup(m)
        return EvilModeModel(manager: m)
    }

    func check(_ name: String, _ view: () -> some View, width: CGFloat? = nil) {
        for look in Look.allCases {
            assertSnapshot(of: Self.render(view(), look: look, width: width), as: .image(precision: 1, perceptualPrecision: 0.98),
                           named: "\(name)-\(look.rawValue)", testName: "evil")
        }
    }

    @Test func modeSwitchAndBadge() {
        check("ModeSwitch.normal") { ModeSwitch(mode: .constant(.normal)) }
        check("ModeSwitch.evil") { ModeSwitch(mode: .constant(.evil)) }
        check("ModeSwitch.locked-evil") { ModeSwitch(mode: .constant(.evil), isLocked: true) }
        check("ModeSwitch.locked-normal") { ModeSwitch(mode: .constant(.normal), isLocked: true) }
        check("EvilBadge") { EvilBadge() }
        check("ModeLockPopover") { ModeLockPopover(current: .evil) { _ in } }
        check("EvilEnableSheet") { EvilEnableSheet(onContinue: {}, onCancel: {}) }
    }

    /// F7 (round 66, vq-m9 s21-evil): with no Evil chats "Delete all…" is disabled and reads disabled (the label in
    /// `text.disabled`, not the `text.secondary` that looked live next to "No Evil chats on this Mac.").
    @Test func deleteAllActsOnlyWithEvilChats() {
        #expect(!EvilSettingsPanel.canDeleteAll(evilChats: 0))
        #expect(EvilSettingsPanel.deleteAllColor(evilChats: 0) == Color.textDisabled)
        #expect(EvilSettingsPanel.canDeleteAll(evilChats: 2))
        #expect(EvilSettingsPanel.deleteAllColor(evilChats: 2) == Color.danger)
    }

    @Test func settingsPanelStates() throws {
        let states: [(String, (EvilModeManager) throws -> Void)] = [
            ("disabled", { _ in }),
            ("enabled", { try $0.enable(adultSelfDeclared: true) }),
            ("hidden", { try $0.enable(adultSelfDeclared: true); $0.setHidden(true) }),
            ("touchid", { try $0.enable(adultSelfDeclared: true); $0.setTouchID(true) }),
        ]
        for (name, setup) in states {
            let model = try Self.panelModel(setup)
            check("EvilSettingsPanel.\(name)", { Form { EvilSettingsPanel(model: model) }.formStyle(.grouped) }, width: 520)
        }
    }
}
}  // extension WindowSuites
