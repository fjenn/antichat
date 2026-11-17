// EvilSnapshotTests (M2.T17 Definition of done): every ModePicker / ModeMenu state (Normal, Evil, locked, downloading), EvilBadge and
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
        // ux/simplify: the toolbar's picker (its face and its menu) replaces the composer's segmented switch.
        check("ModePicker.normal") { ModePicker(mode: .constant(.normal)) }
        check("ModePicker.evil") { ModePicker(mode: .constant(.evil)) }
        check("ModePicker.hover-evil") { ModePickerLabel(mode: .evil, highlighted: true) }
        check("ModeToggle.evil") { ModeToggle(mode: .constant(.evil)) }
        let menu = { (current: ComposerChatMode, locked: Bool, line: CopyText?) in
            ModeMenu(current: current, isLocked: locked, evilUnavailable: line, onPick: { _ in }, onContinue: { _ in })
                .background(Color.surfaceRaised)
        }
        check("ModeMenu.normal") { menu(.normal, false, nil) }
        check("ModeMenu.evil") { menu(.evil, false, nil) }
        check("ModeMenu.locked-evil") { menu(.evil, true, nil) }
        check("ModeMenu.locked-normal") { menu(.normal, true, nil) }
        check("ModeMenu.downloading") { menu(.normal, false, CopyText(CopyKey("evil.downloading"), ["minutes": "6"])) }
        check("EvilBadge") { EvilBadge() }
        check("EvilEmptyState", {
            let m = ComposerModel(evilEnabled: true)
            m.mode = .evil
            return EvilEmptyState { ComposerView(model: m) }.frame(height: 420).environment(\.readingWidth, 640)
        }, width: 820)
        check("EvilEnableSheet") { EvilEnableSheet(onContinue: {}, onCancel: {}) }
    }

    /// Owner 2026-11-17: a new, empty chat shows the Normal / Evil choice above the composer (only while Evil Mode is
    /// offered): Normal chosen, Evil chosen, Evil not ready (disabled, with its line), and absent with Evil Mode off.
    @Test func emptyStateModeChoice() {
        let line = CopyText(CopyKey("evil.setup.downloading"), ["percent": "42"])
        let empty = { (mode: ComposerChatMode, offered: Bool, unavailable: CopyText?) -> AnyView in
            let m = ComposerModel(evilEnabled: offered)
            m.mode = mode
            let control = offered ? AnyView(EmptyModeControl(mode: .constant(mode), evilUnavailable: unavailable)) : nil
            let view = mode == .evil
                ? AnyView(EvilEmptyState(modeControl: control) { ComposerView(model: m) })
                : AnyView(EmptyStateView(headline: CopyKey("empty.headline"),
                                         suggestions: SuggestionProvider.suggestions(enabled: [.chat], seed: 1),
                                         onSuggestion: { _ in }, modeControl: control) { ComposerView(model: m) })
            return AnyView(view.frame(height: 460).environment(\.readingWidth, 640))
        }
        check("EmptyMode.normal", { empty(.normal, true, nil) }, width: 820)
        check("EmptyMode.evil", { empty(.evil, true, nil) }, width: 820)
        check("EmptyMode.notReady", { empty(.normal, true, line) }, width: 820)
        check("EmptyMode.off", { empty(.normal, false, nil) }, width: 820)
        check("EmptyModeControl.normal") { EmptyModeControl(mode: .constant(.normal)) }
        check("EmptyModeControl.evil") { EmptyModeControl(mode: .constant(.evil)) }
        check("EmptyModeControl.notReady") { EmptyModeControl(mode: .constant(.normal), evilUnavailable: line) }
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
        // Off, with no Evil chats and no Evil models, the group is not there at all (the switch is the Evil row of the
        // pack list: `evilRowOfThePackList`).
        let states: [(String, (EvilModeManager) throws -> Void)] = [
            ("enabled", { try $0.enable(adultSelfDeclared: true) }),
            ("hidden", { try $0.enable(adultSelfDeclared: true); $0.setHidden(true) }),
            ("touchid", { try $0.enable(adultSelfDeclared: true); $0.setTouchID(true) }),
        ]
        for (name, setup) in states {
            let model = try Self.panelModel(setup)
            check("EvilSettingsPanel.\(name)", { Form { EvilSettingsPanel(model: model) }.formStyle(.grouped) }, width: 520)
        }
    }

    /// Owner 2026-11-16: Evil is the fifth row of the Capabilities list — name, state (Off / Ready), the one switch.
    @Test func evilRowOfThePackList() throws {
        let off = try Self.panelModel { _ in }
        let on = try Self.panelModel { try $0.enable(adultSelfDeclared: true) }
        #expect(!off.isOn && on.isOn)
        check("EvilPackRow.off", { Form { Section { EvilPackRow(model: off) } }.formStyle(.grouped) }, width: 520)
        check("EvilPackRow.on", { Form { Section { EvilPackRow(model: on) } }.formStyle(.grouped) }, width: 520)
    }
}
}  // extension WindowSuites
