// Shared rig for the M1.T09 renderer tests: host a view in an offscreen window (explicit appearance, brand accent,
// Reduce Motion on, as the T03/T08 snapshot rigs), let MarkdownView's off-main parse, highlighting and math settle,
// then capture at 2x. Fixture lookup: $ANTICHAT_FIXTURES/render, fixtures/render (submodule), tools/fixtures/render.
import AppKit
import SwiftUI
@testable import AntiChatDesign
@testable import AntiChatUI

enum RendererRig {
    enum Look: String, CaseIterable {
        case light, dark
        var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
        var scheme: ColorScheme { self == .light ? .light : .dark }
    }

    static let width: CGFloat = 640

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The golden-100 directory to read (first existing) and the staging one to record into.
    static var goldenDir: URL {
        var c: [URL] = []
        if let f = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"] {
            c.append(URL(fileURLWithPath: f).appendingPathComponent("render/golden-100"))
        }
        c.append(repoRoot.appendingPathComponent("fixtures/render/golden-100"))
        c.append(stagingGoldenDir)
        return c.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("001.md").path) } ?? stagingGoldenDir
    }

    static var stagingGoldenDir: URL { repoRoot.appendingPathComponent("tools/fixtures/render/golden-100") }

    @MainActor
    final class Host {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        let look: Look
        /// This host's own pasteboard for the Copy buttons (the general one is shared with parallel tests).
        let pasteboard: NSPasteboard

        init(_ view: some View, look: Look, width: CGFloat = RendererRig.width) {
            DesignBundle.forceBrandAccent = true
            self.look = look
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("antichat-test-\(UUID().uuidString)"))
            self.pasteboard = pasteboard
            let root = AnyView(
                view
                    .frame(width: width, alignment: .topLeading)
                    .padding(Spacing.space4)
                    .background(Color.surfaceCanvas)
                    .environment(\.reduceMotionOverride, true)
                    .environment(\.colorScheme, look.scheme)
                    .environment(\.pasteboard, pasteboard))
            host = NSHostingView(rootView: root)
            host.appearance = look.appearance
            window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.appearance = look.appearance
            window.contentView = host
            // SwiftUI starts `.task`/`onAppear` work (MarkdownView's off-main parse) only for a window that is
            // ordered in: order it in far off-screen, never key, invisible to the user.
            window.setFrameOrigin(CGPoint(x: -20_000, y: -20_000))
            BackgroundRun.present(window)  // alpha 0, never key
            layout()
        }

        isolated deinit {
            window.orderOut(nil)
            pasteboard.releaseGlobally()
        }

        func layout() {
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = CGRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
        }

        /// Yields the main actor until the size is stable for `stableFor` seconds (async parse, highlight, math).
        /// Must await, not spin the run loop: main-actor jobs (MarkdownView's render loop) cannot run while a
        /// synchronous test body holds the main actor.
        /// `minHeight`: keep waiting (up to `max`) until the content is at least this tall (the async parse landed).
        func settle(min: Double = 0.25, stableFor: Double = 0.2, max: Double = 4, minHeight: CGFloat = 0) async {
            let start = Date()
            var last = CGSize.zero
            var stableSince = Date()
            while Date().timeIntervalSince(start) < max {
                try? await Task.sleep(for: .milliseconds(20))
                layout()
                let s = host.frame.size
                if s != last { last = s; stableSince = Date() }
                if Date().timeIntervalSince(start) >= min, Date().timeIntervalSince(stableSince) >= stableFor,
                    s.height >= minHeight { break }
            }
        }

        func image() -> NSImage {
            let size = host.frame.size
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int((size.width * 2).rounded()),
                pixelsHigh: Int((size.height * 2).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = size
            look.appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
            let image = NSImage(size: size)
            image.addRepresentation(rep)
            return image
        }

        /// Frames (window coordinates) of probe anchors with `id`.
        func frames(_ id: String) -> [CGRect] { UIProbeRegistry.frames(id, in: window) }

        /// A real click at the centre of the first anchor `id`.
        @discardableResult
        func click(_ id: String) -> Bool {
            guard let f = frames(id).first else { return false }
            let p = CGPoint(x: f.midX, y: f.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(
                    with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { return false }
                window.sendEvent(e)
            }
            return true
        }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
