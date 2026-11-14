// ComponentSnapshotTests (M1.T03 step 8; test-strategy §4.3): every base-component state × Light/Dark × 100 %/200 %
// text size, per-pixel ΔE ≤ 2 (SnapshotTesting perceptualPrecision 0.98 = CIE94 ΔE ≤ 2 per pixel, precision 1:
// every pixel must pass). Rendering is pinned: bitmap scale 2.0, explicit NSAppearance, brand accent, Reduce
// Motion on (no transitions in flight). References: __Snapshots__/ComponentSnapshotTests/.
// Re-record after an intended visual change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ComponentSnapshotTests.
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign

enum Look: String, CaseIterable {
    case light, dark
    var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
}

let textScales: [(String, CGFloat)] = [("100", 1.0), ("200", 2.0)]

/// Renders a SwiftUI view at bitmap scale 2.0 in an offscreen window with a fixed appearance.
@MainActor
func render<V: View>(_ view: V, look: Look, textScale: CGFloat, width: CGFloat?, backdrop: Color) -> NSImage {
    DesignBundle.forceBrandAccent = true
    let root = view
        .frame(width: width, alignment: .leading)
        .fixedSize(horizontal: width == nil, vertical: true)
        .padding(Spacing.space4)
        .background(backdrop)
        .environment(\.chatTextScale, textScale)
        .environment(\.reduceMotionOverride, true)
        .environment(\.colorScheme, look == .light ? .light : .dark)
    let host = NSHostingView(rootView: root)
    host.appearance = look.appearance
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = look.appearance
    window.contentView = host
    let size = host.fittingSize
    window.setContentSize(size)
    host.frame = CGRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded()),
                               pixelsHigh: Int((size.height * 2).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!
    rep.size = size
    look.appearance.performAsCurrentDrawingAppearance {
        host.cacheDisplay(in: host.bounds, to: rep)
    }
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}

/// One component state rendered in every look × text scale.
@MainActor
func assertStates(_ name: String, width: CGFloat? = nil, backdrop: Color = .surfaceCanvas,
                  states: [(String, AnyView)], filePath: StaticString = #filePath, function: String = #function,
                  line: UInt = #line, column: UInt = #column) {
    for (state, view) in states {
        for look in Look.allCases {
            for (scaleName, scale) in textScales {
                let image = render(view, look: look, textScale: scale, width: width, backdrop: backdrop)
                assertSnapshot(of: image, as: .image(precision: 1, perceptualPrecision: 0.98),
                               named: "\(name).\(state)-\(look.rawValue)-\(scaleName)",
                               fileID: #fileID, file: filePath, testName: "components", line: line, column: column)
            }
        }
    }
}

/// A copy-deck key for a snapshot; an unknown key fails the test (copy-sync only sees `CopyKey("…")` literals).
func copy(_ k: String, sourceLocation: SourceLocation = #_sourceLocation) -> CopyText {
    #expect(CopyKey(k).isKnown, "unknown copy key \(k)", sourceLocation: sourceLocation)
    return CopyText(CopyKey(k))
}

/// Onboarding pills sit on art; the snapshot backdrop is the Reduce Transparency card colour `#2B2B2B`
/// (tokens.md §1.6), the darkest neutral the pills are designed for.
let onboardingBackdrop = Color(tokenHex: 0x2B2B_2BFF)

@MainActor
@Suite(.serialized) struct ComponentSnapshotTests {
    @Test func pillButton() {
        var states: [(String, AnyView)] = PillButton.Style.allCases.map { style in
            (style.rawValue, AnyView(PillButton(copy("onb.cta.continue"), style: style) {}))
        }
        for s in [InteractionState.hover, .pressed, .focused] {
            states.append(("primary-\(s.rawValue)", AnyView(PillButton(copy("onb.1.cta")) {}.interactionState(s))))
        }
        states.append(("disabled", AnyView(PillButton(copy("onb.cta.continue"),
                                                      disabledReason: CopyText(CopyKey("onb.diskShort"), ["gb": "4.2"])) {})))
        states.append(("loading", AnyView(PillButton(copy("onb.4.cta"), style: .dark, isLoading: true) {})))
        assertStates("PillButton", backdrop: onboardingBackdrop, states: states)
    }

    @Test func tooltip() {
        assertStates("Tooltip", states: [
            ("label", AnyView(Tooltip(copy("tip.think")))),
            ("shortcut", AnyView(Tooltip(copy("side.newChat"), shortcut: "⌘N"))),
        ])
    }

    @Test func toast() {
        assertStates("Toast", states: [
            ("info", AnyView(ToastView(Toast(.info, copy("model.usingLighter"))))),
            ("success", AnyView(ToastView(Toast(.success, copy("starter.upgraded"))))),
            ("warning-action", AnyView(ToastView(Toast(.warning, CopyText(CopyKey("upload.unsupported"), ["ext": ".pages"]),
                                                       action: ToastAction(copy("msg.retry")) {})))),
        ])
    }

    @Test func banner() {
        assertStates("Banner", width: 560, states: [
            ("warning-dismissible", AnyView(Banner(.warning, copy("permission.notifications.off"), onDismiss: {}))),
            ("info-action", AnyView(Banner(.info, copy("catalog.expired"),
                                           action: Banner.Action(copy("set.updates.check")) {}, onDismiss: {}))),
            ("danger-sticky", AnyView(Banner(.danger, copy("engine.crashLoop"),
                                             action: Banner.Action(copy("engine.restartApp")) {}))),
        ])
    }

    @Test func settingsRow() {
        assertStates("SettingsRow", width: 560, states: [
            ("default", AnyView(SettingsRow(copy("set.updates.auto")) {
                Toggle(isOn: .constant(true)) { Text(CopyKey("set.updates.auto")) }
            })),
            ("description", AnyView(SettingsRow(copy("set.privacy.offlineOnly"),
                                                description: copy("set.privacy.offlineOnly.note")) {
                Toggle(isOn: .constant(false)) { Text(CopyKey("set.privacy.offlineOnly")) }
            })),
            ("disabled-reason", AnyView(SettingsRow(copy("set.evil.touchid"),
                                                    disabledReason: copy("onb.3.availability.none")) {
                Toggle(isOn: .constant(false)) { Text(CopyKey("set.evil.touchid")) }
            })),
            ("requires-restart", AnyView(SettingsRow(copy("set.tools.code"), requiresRestart: true) {
                Toggle(isOn: .constant(true)) { Text(CopyKey("set.tools.code")) }
            })),
        ])
    }

    @Test func errorInline() {
        assertStates("ErrorInline", width: 560, states: [
            ("message-only", AnyView(ErrorInline(copy("model.notEnoughMemory")))),
            ("retry", AnyView(ErrorInline(copy("engine.restarted"), actions: [.init(copy("msg.retry")) {}]))),
            ("primary-action", AnyView(ErrorInline(copy("engine.versionMismatch"),
                                                   actions: [.init(copy("engine.restartApp"), role: .primary) {}]))),
            ("two-actions", AnyView(ErrorInline(copy("engine.crashLoop"), actions: [
                .init(copy("set.about.report")) {}, .init(copy("engine.restartApp"), role: .primary) {},
            ]))),
        ])
    }
}
