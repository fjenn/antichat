// M2.T18 Definition of done: PackCard snapshots (default / ticked / unticked / dimmed / focused / size-updating) at
// 100% and 200% text size, plus full-window renders of steps 1–2 at 1280 × 800 and 1000 × 700 (2 × 2 wrap) for the
// visual QA folder (written only with ANTICHAT_ONB_SHOTS). Onboarding is always dark: Light and Dark system appearances
// render the same.
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=OnboardingSnapshotTests.
// ANTICHAT_ONB_SHOTS=<dir> also writes the full-window PNGs there.
import AntiChatFoundation
import AntiChatPlatform
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct OnboardingSnapshotTests {
    typealias Look = ComposerSnapshotTests.Look

    static func render(_ view: some View, size: CGSize, look: Look) -> NSImage {
        DesignBundle.forceBrandAccent = true
        let root = view.frame(width: size.width, height: size.height).environment(\.reduceMotionOverride, true)
        let host = NSHostingView(rootView: root)
        host.appearance = look.appearance
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = look.appearance
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        look.appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func write(_ image: NSImage, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["ANTICHAT_ONB_SHOTS"],
              let rep = image.representations.first as? NSBitmapImageRep, let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @Test func fullWindowSteps() {
        let cases: [(String, LaunchOptions.Tier, Int64, CGSize, OnboardingModel.Step, Bool)] = [
            ("step1-welcome", .T1, 500, CGSize(width: 1280, height: 800), .welcome, true),
            ("step2-T1", .T1, 500, CGSize(width: 1280, height: 800), .capabilities, true),
            ("step2-T0", .T0, 500, CGSize(width: 1280, height: 800), .capabilities, true),
            ("step2-T4", .T4, 2000, CGSize(width: 1280, height: 800), .capabilities, true),
            ("step2-diskShort", .T1, 15, CGSize(width: 1280, height: 800), .capabilities, true),
            ("step2-noInternet", .T2, 500, CGSize(width: 1280, height: 800), .capabilities, false),
            ("step2-wrap-1000", .T3, 500, CGSize(width: 1000, height: 700), .capabilities, true),
        ]
        for (name, tier, free, size, step, online) in cases {
            for look in Look.allCases {
                // This build's step 2: every pack ships since M4.T16 (ModelPack.shipped, lead decision B).
                let m = OnboardingModelTests.model(tier, freeGB: free, online: online, shipped: ModelPack.shipped)
                m.step = step
                let img = Self.render(OnboardingFlow(model: m), size: size, look: look)
                Self.write(img, "\(name)-\(look.rawValue)")
                // Full windows are visual-QA renders (ANTICHAT_ONB_SHOTS), not committed references (≈ 3 MB each).
                #expect(img.size == size)
            }
        }
    }

    /// M2.T19 step 3 states (vq-01 § step 3): off, on-unticked, on-ticked, disk-short.
    @Test func evilStepRenders() {
        let probe = OnboardingModelTests.model(.T1)
        let tight = Int64((Double(probe.totalBytes + DiskPreflight.headroomBytes) / 1e9).rounded(.up))
        let cases: [(String, Int64, Bool, Bool)] = [("off", 500, false, false), ("on-unticked", 500, true, false),
                                                   ("on-ticked", 500, true, true), ("diskShort", tight, true, true)]
        for (name, free, on, adult) in cases {
            for look in Look.allCases {
                let m = OnboardingModelTests.model(.T1, freeGB: free)
                m.step = .evil
                m.evilOn = on
                m.adultConfirmed = adult
                let img = Self.render(OnboardingFlow(model: m), size: CGSize(width: 1280, height: 800), look: look)
                Self.write(img, "step3-\(name)-\(look.rawValue)")
                #expect(img.size.width == 1280)
            }
        }
        Self.write(Self.render(OnboardingBackground(step: .evil), size: CGSize(width: 1280, height: 800), look: .dark), "bg-step3")
    }

    /// M10 visual QA (S-04): step 4 while downloading, and with every pack failed (Retry leads, no "start typing").
    @Test func preparingStepRenders() {
        func status(_ state: SetupProgress.RowState, starter: Bool = false) -> SetupStatus {
            let st = SetupStatus()
            st.progress = SetupProgress(rows: ["chat", "voice", "photo"].map {
                SetupProgress.Row(group: $0, state: state, bytesDone: 30, bytesTotal: 100)
            } + [SetupProgress.Row(group: "evil", state: .waiting, bytesDone: 0, bytesTotal: 100)],
                starterReady: starter, tierReady: false, tierPercent: 0, starterFraction: starter ? 1 : 0, evilRemainingBytes: 0,
                evilVerifying: false)
            return st
        }
        // Review S2: failed with nothing answering → Continue without Chat beside Retry; with the starter → Open chat.
        for (name, state, starter) in [("downloading", SetupProgress.RowState.downloading(percent: 30), false), ("failed", .failed, false),
                                       ("failed-starter", .failed, true)] {
            let m = OnboardingModelTests.model(.T1)
            m.step = .preparing
            m.evilOn = true
            let img = Self.render(OnboardingFlow(model: m, status: status(state, starter: starter)), size: CGSize(width: 1280, height: 800),
                                  look: .dark)
            Self.write(img, "step4-\(name)")
            #expect(img.size.width == 1280)
        }
    }

    /// Backgrounds only (art + scrim, no text) for tools/visual/contrast-sampler.py (H3, AT-201 part 1).
    @Test func backgroundsForContrastSampling() {
        for step in [OnboardingModel.Step.welcome, .capabilities] {
            let img = Self.render(OnboardingBackground(step: step), size: CGSize(width: 1280, height: 800), look: .dark)
            Self.write(img, "bg-step\(step.rawValue)")
        }
    }

    @Test func packCardStates() {
        let m = OnboardingModelTests.model(.T1)
        let chat = m.cards[0], voice = m.cards[1], photo = m.cards[2], video = m.cards[3]
        var unticked = photo
        unticked.ticked = false
        let states: [(String, OnboardingModel.Card, Bool)] = [
            ("default", chat, false), ("ticked", voice, false), ("unticked", unticked, false), ("dimmed", video, false),
            ("focused", photo, true),
            // No pack is "Coming soon" in this build (all ship since M4.T16); the state is rendered with Photo held back.
            ("comingSoon", OnboardingModelTests.model(.T1, shipped: [.chat, .voice, .video]).cards.first { $0.pack == .photo }!, false),
        ]
        for (name, card, focused) in states {
            for scale in [1.0, 2.0] {
                let v = PackCard(card: card, sizeLine: m.sizeLine(card), isFocused: focused)
                    .frame(width: 232, height: scale > 1 ? 200 : 124)
                    .dynamicTypeSize(scale > 1 ? .accessibility3 : .large)
                    .padding(20)
                    .background(Color(white: 0.2))
                let img = Self.render(v, size: CGSize(width: 272, height: scale > 1 ? 240 : 164), look: .dark)
                assertSnapshot(of: img, as: .image(precision: 0.98, perceptualPrecision: 0.97), named: "PackCard.\(name)-\(Int(scale * 100))",
                               testName: "onboarding")
            }
        }
        // size-updating: the line follows the model (a measured throughput replaces the 50 Mbps assumption).
        m.measuredBytesPerSecond = 50_000_000
        #expect(m.sizeLine(voice) != OnboardingModelTests.model(.T1).sizeLine(voice))
    }
}
}
