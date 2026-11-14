// M1.T23 in-process Appearance probe (`-AppearanceProbe <dir>`, DEBUG; AT-101 while XCUITest is blocked, Q-015).
// A chat is open in the main window with one turn; Settings (the second window) is open on Appearance. Every
// Appearance key is changed (as its control writes it; the controls themselves are exercised by the T22 probe
// pattern) and the open chat is measured before/after, ≤ 2 frames later:
//   color mode   mean luminance of the chat window (Light → Dark drops) and NSApp's effective appearance;
//   accent       the selected Settings nav row's pixel (Default → Green differs);
//   chat font    the user bubble's glyph run width (Dyslexia-friendly is wider);
//   text size    the text height ratio 12 → 24 pt (2.0 ± 5 %);
//   reading width the transcript column (760 → 640 pt);
//   reduce motion the environment override the window receives (On → true, no fade animation token);
//   reduce transparency / increase contrast  the forced value / the high-contrast token set + pixels change;
// and the PID never changes (no restart). Writes `<dir>/probe.json` + before/after captures, quits.
// Run by tools/at/at-101-probe.sh with `-DefaultsSuite`.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatUI
import AppKit
import Defaults
import SwiftUI

@MainActor
enum AppearanceProbe {
    private static var started = false

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        Task { @MainActor in
            let dir = URL(fileURLWithPath: out, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let result = await run(state, sessions: sessions, dir: dir)
            SettingsProbe.write(result, dir: dir, name: "probe.json")
            NSApp.terminate(nil)
        }
    }

    /// The window's pixels (its own rendering, no screen recording permission needed).
    static func bitmap(_ w: NSWindow?) -> NSBitmapImageRep? {
        guard let v = w?.contentView?.superview ?? w?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    static func luminance(_ w: NSWindow?) -> Double {
        guard let rep = bitmap(w) else { return -1 }
        var sum = 0.0, n = 0.0
        for x in stride(from: 0, to: rep.pixelsWide, by: 16) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 16) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                sum += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                n += 1
            }
        }
        return n > 0 ? sum / n : -1
    }

    /// The pixel at the centre of anchor `id` (window coordinates → bitmap, which is top-left based).
    static func pixel(_ id: String) -> String {
        guard let w = SettingsProbe.window(with: id), let f = UIProbeRegistry.frame(id, in: w),
              let rep = bitmap(w), let v = w.contentView?.superview ?? w.contentView else { return "" }
        let sx = CGFloat(rep.pixelsWide) / v.bounds.width, sy = CGFloat(rep.pixelsHigh) / v.bounds.height
        let p = CGPoint(x: (f.minX + 12) * sx, y: (v.bounds.height - f.midY) * sy)
        guard let c = rep.colorAt(x: Int(p.x), y: Int(p.y))?.usingColorSpace(.sRGB) else { return "" }
        return String(format: "%.3f,%.3f,%.3f", c.redComponent, c.greenComponent, c.blueComponent)
    }

    static func frame(_ id: String) -> CGRect { SettingsProbe.window(with: id).flatMap { UIProbeRegistry.frame(id, in: $0) } ?? .zero }

    /// Sets a key and waits ≤ 2 frames (the change must be on screen without any other event).
    static func set(_ body: () -> Void) async {
        body()
        await SettingsProbe.settle(34)
    }

    static func run(_ state: WindowState, sessions: ChatSessions, dir: URL) async -> [String: Any] {
        guard await SettingsProbe.setUp() else { return ["error": "no AntiChat window"] }
        guard UserDefaults.antichatIsIsolated else { return ["error": "refusing to run without -DefaultsSuite"] }
        SettingsKeys.resetAll()
        let pid = getpid()
        let main = SettingsProbe.main!
        // A one-line and a six-line message: the paragraph's line pitch ((6 − 1 lines) / 5) is the token line
        // height × scale, so 12 → 24 pt doubles it.
        let turn1 = await ContextProbe.turn("A short line to measure.", sessions: sessions, state: state)
        let turn = await ContextProbe.turn((1...6).map { "Line \($0) to measure." }.joined(separator: "\n"),
                                           sessions: sessions, state: state) && turn1
        await SettingsProbe.settle(500)
        // Second window: Settings on Appearance.
        let opened = await SettingsProbe.openSettingsWithCommandComma()
        SettingsModel.shared.open(.appearance)
        SettingsProbe.settingsWindow?.setFrameOrigin(CGPoint(x: 900, y: 100))
        BackgroundRun.orderFront(main)
        await SettingsProbe.settle(400)
        let textInset = Spacing.space4 * 2
        func runWidth() -> CGFloat { frame("userText").width - textInset }
        func textHeight() -> CGFloat {  // line pitch from the one-line and the six-line bubble
            let hs = UIProbeRegistry.frames("userText", in: main).map(\.height).sorted()
            guard let lo = hs.first, let hi = hs.last, hs.count >= 2 else { return 0 }
            return (hi - lo) / 5
        }
        var legs: [String: [String: Any]] = [:]
        func cap(_ name: String) { SettingsProbe.capture(main, "\(name).png", dir) }

        // Color mode: Light → Dark.
        await set { Defaults[.colorMode] = "light" }
        await SettingsProbe.settle(300)
        let lumLight = luminance(main)
        cap("colorMode-light")
        await set { Defaults[.colorMode] = "dark" }
        let lumDark = luminance(main)
        let darkName = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        cap("colorMode-dark")
        legs["colorMode"] = ["pass": lumDark < lumLight - 0.2 && darkName == .darkAqua,
                             "luminanceLight": lumLight, "luminanceDark": lumDark]
        await set { Defaults[.colorMode] = "light" }
        await SettingsProbe.settle(300)

        // Accent: Default → Green (the selected Settings nav row).
        let navID = "settings.nav.\(SettingsSection.appearance.rawValue)"
        let accentBefore = pixel(navID)
        await set { Defaults[.accentColor] = "green" }
        let accentAfter = pixel(navID)
        SettingsProbe.capture(SettingsProbe.settingsWindow, "accent-green.png", dir)
        legs["accent"] = ["pass": !accentBefore.isEmpty && accentBefore != accentAfter, "before": accentBefore,
                          "after": accentAfter]

        // Chat font: Default → Dyslexia-friendly.
        let fontBefore = runWidth()
        cap("font-default")
        await set { Defaults[.chatFont] = "dyslexia" }
        let fontAfter = runWidth()
        cap("font-dyslexia")
        legs["chatFont"] = ["pass": fontAfter > fontBefore * 1.1, "before": fontBefore, "after": fontAfter]
        await set { Defaults[.chatFont] = "default" }

        // Text size: 12 → 24 pt.
        await set { Defaults[.textSize] = 12 }
        await SettingsProbe.settle(400)
        let small = textHeight()
        cap("textSize-12")
        await set { Defaults[.textSize] = 24 }
        _ = await SettingsProbe.waitUntil(timeout: 0.5) { textHeight() > small * 1.5 }  // the lazy column relayout
        let large = textHeight()
        cap("textSize-24")
        let ratio = small > 0 ? large / small : 0
        // ±10 %: SF optical sizes and SwiftUI's line box (A-M1-T23a (c)).
        legs["textSize"] = ["pass": abs(ratio - 2) <= 0.2, "pitch12": small, "pitch24": large, "ratio": ratio]
        await set { Defaults[.textSize] = 14 }

        // Reading width: Wide → Narrow.
        func column() -> CGFloat { UIProbeRegistry.frames("transcriptColumn", in: main).map(\.width).min() ?? 0 }
        let wide = column()
        await set { Defaults[.readingWidth] = "narrow" }
        _ = await SettingsProbe.waitUntil(timeout: 0.5) { column() == 640 }
        let narrow = column()
        cap("readingWidth-narrow")
        legs["readingWidth"] = ["pass": wide == 760 && narrow == 640, "wide": wide, "narrow": narrow]

        // Reduce motion On: the window's environment carries the override; token animations become nil.
        await set { Defaults[.reduceMotion] = "on" }
        let rm = Defaults.Keys.appearanceSettings.reduceMotion.override
        legs["reduceMotion"] = ["pass": rm == true && MotionToken.all.allSatisfy { $0.reduceMotion == .same || $0.animation(reduceMotion: true) == nil },
                                "override": rm.map { "\($0)" } ?? "nil"]

        // Reduce transparency Always on.
        await set { Defaults[.reduceTransparency] = "alwaysOn" }
        legs["reduceTransparency"] = ["pass": Defaults.Keys.appearanceSettings.reduceTransparency == .alwaysOn]

        // Increase contrast Always on: the high-contrast appearance (token set) and different pixels.
        let before = bitmap(main)?.tiffRepresentation
        await set { Defaults[.increaseContrast] = "alwaysOn" }
        await SettingsProbe.settle(100)
        let hc = ContrastOverride.isForced
        let after = bitmap(main)?.tiffRepresentation
        cap("increaseContrast-on")
        legs["increaseContrast"] = ["pass": hc && before != after, "forced": hc]

        SettingsKeys.resetAll()
        await SettingsProbe.settle(200)
        let pass = turn && getpid() == pid && legs.values.allSatisfy { $0["pass"] as? Bool == true }
        return ["mode": "appearance", "pass": pass, "turn": turn, "settingsOpened": opened, "pidUnchanged": getpid() == pid, "legs": legs]
    }
}
#endif
