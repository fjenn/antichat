// M10 visual QA: renders of the What's new sheet, the first-use tour card and the in-app primary button in Light and
// Dark, written to ANTICHAT_ONB_SHOTS for the visual-QA folder (not committed references). The checks are on the
// pieces the blind panel named: Continue is the `button.primary` pill (not the grey default button), the tour card has
// no full-width action, and the primary label keeps ≥ 4.5:1 on its fill in both appearances.
import AntiChatDesign
import AppKit
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct M10SurfaceRenderTests {
    typealias Look = ComposerSnapshotTests.Look

    static func render(_ view: some View, size: CGSize, look: Look) -> NSImage {
        let root = view
            .frame(width: size.width, height: size.height)
            .background(Color.surfaceCanvas)
            .environment(\.colorScheme, look == .light ? .light : .dark)
        return OnboardingSnapshotTests.render(root, size: size, look: look)
    }

    @Test func whatsNewSheet() {
        let notes = WhatsNewNotes(version: "0.0.1", items: [
            .init(icon: "arrow.down.app", title: "Updates itself", body: "New versions download in the background and install when you restart."),
            .init(icon: "folder", title: "Move to Applications", body: "Opened from the disk image, AntiChat offers to move itself."),
            .init(icon: "questionmark.circle", title: "Help that works offline", body: "Help › AntiChat Help opens a short guide, no internet needed."),
        ])
        for look in Look.allCases {
            let img = Self.render(WhatsNewSheet(notes: notes) {}, size: CGSize(width: 440, height: 360), look: look)
            OnboardingSnapshotTests.write(img, "m10-whatsnew-\(look.rawValue)")
            #expect(img.size.width == 440)
        }
    }

    @Test func tourCard() {
        let tip = TourTip(packs: [.chat, .voice, .photo])
        for look in Look.allCases {
            let v = VStack {
                TourCard(image: tip.image, title: tip.title, message: tip.message) {}.frame(maxWidth: 520)
                Spacer()
            }
            .padding(.top, Spacing.space5)
            let img = Self.render(v, size: CGSize(width: 760, height: 120), look: look)
            OnboardingSnapshotTests.write(img, "m10-tour-\(look.rawValue)")
            #expect(img.size.width == 760)
        }
    }

    @Test func primaryButtonLabelContrast() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let ap = try #require(NSAppearance(named: name))
            var bg = NSColor.clear, fg = NSColor.clear
            ap.performAsCurrentDrawingAppearance {
                bg = NSColor.buttonPrimaryBg.usingColorSpace(.sRGB)!
                fg = NSColor.buttonPrimaryFg.usingColorSpace(.sRGB)!
            }
            #expect(Self.contrast(bg, fg) >= 4.5, "\(name.rawValue)")
            // The segmented-picker fill keeps the platform's white label at ≥ 4.5:1 too (every preset).
            for preset in AccentPreset.allCases {
                var fill = NSColor.clear
                ap.performAsCurrentDrawingAppearance { fill = preset.fillNSColor.usingColorSpace(.sRGB)! }
                #expect(Self.contrast(fill, .white.usingColorSpace(.sRGB)!) >= 4.5, "\(preset) \(name.rawValue)")
            }
        }
        let img = Self.render(HStack(spacing: 12) {
            Button("Send") {}.buttonStyle(PrimaryButtonStyle())
            Button("Use this version") {}.buttonStyle(PrimaryButtonStyle()).controlSize(.small)
        }, size: CGSize(width: 300, height: 60), look: .dark)
        OnboardingSnapshotTests.write(img, "m10-primary-dark")
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func lum(_ c: NSColor) -> Double {
            func lin(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.04045 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
}
