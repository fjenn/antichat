// ComposerSnapshotTests (M1.T08 Definition of done; test-strategy §4.3): every Composer state of components.md §2
// that exists in M1 — empty, typing, multi-line, with attachments, queued, generating, disabled (no model),
// drag-over, Incognito, plus Evil — in Light and Dark. Same rig as the T03 ComponentSnapshotTests (bitmap scale
// 2.0, explicit NSAppearance, brand accent, Reduce Motion on; per-pixel ΔE ≤ 2).
// Re-record after an intended visual change: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ComposerSnapshotTests.
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ComposerSnapshotTests {
    enum Look: String, CaseIterable {
        case light, dark
        var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
    }

    static let width: CGFloat = 640

    static func render(_ model: ComposerModel, look: Look) -> NSImage {
        DesignBundle.forceBrandAccent = true
        let root = ComposerView(model: model)
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
        // Two layout passes: the text view reports its line count after the first.
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

    static func states() -> [(String, () -> ComposerModel)] {
        [
            ("empty", { ComposerModel() }),
            ("typing", { let m = ComposerModel(); m.text = "What's the **fastest** way to learn Swift?"; return m }),
            ("multi-line", {
                let m = ComposerModel()
                m.text = "First line\nSecond line with *emphasis*\n- a list item\n- `code` item"
                m.lineCount = 4
                m.textWraps = true
                return m
            }),
            ("attachments", {
                let m = ComposerModel()
                m.handlePaste(String(repeating: "Lorem ipsum dolor sit amet. ", count: 400))
                m.text = "Summarise this"
                return m
            }),
            ("queued", { let m = ComposerModel(); m.availability = .queued(percent: 42); m.text = "Hello"; return m }),
            ("generating", { let m = ComposerModel(); m.text = "Hello"; m.send(); return m }),
            ("disabled-no-model", { let m = ComposerModel(); m.availability = .noModel; return m }),
            ("drag-over", { let m = ComposerModel(); m.isDragOver = true; return m }),
            ("incognito", { let m = ComposerModel(); m.isIncognito = true; return m }),
            ("evil", {
                let m = ComposerModel(evilEnabled: true)
                m.mode = .evil
                m.text = "Hello"
                return m
            }),
            ("status-row", {
                let m = ComposerModel()
                m.statusProjectName = "Fixture project"
                m.statusMode = .evil
                return m
            }),
        ]
    }

    @Test func composerStates() {
        for (name, make) in Self.states() {
            for look in Look.allCases {
                let image = Self.render(make(), look: look)
                assertSnapshot(of: image, as: .image(precision: 1, perceptualPrecision: 0.98),
                               named: "Composer.\(name)-\(look.rawValue)", testName: "composer")
            }
        }
    }
}
}  // extension WindowSuites
