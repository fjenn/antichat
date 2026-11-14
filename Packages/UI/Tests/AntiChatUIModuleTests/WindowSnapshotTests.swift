// M1.T07 definition of done: snapshots of MainWindow (normal, narrow), ChatRow (default, hover, selected,
// streaming, renaming, deleting) and EmptyState (Normal), light and dark. Same rig as AntiChatDesign's
// ComponentSnapshotTests (bitmap scale 2.0, pinned appearance, brand accent, Reduce Motion on, ΔE ≤ 2).
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=WindowSnapshotTests.
import AntiChatDesign
import AntiChatHarness
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatUI

enum Look: String, CaseIterable {
    case light, dark
    var appearance: NSAppearance { NSAppearance(named: self == .light ? .aqua : .darkAqua)! }
}

/// The render window reports a fixed backing scale (2×, the capture's), so layout rounding (AppKit-backed views such
/// as TextField's NSTextField, and SwiftUI, which takes `\.displayScale` from the window) is the same on every Mac and
/// display setup. An offscreen window otherwise takes the scale of whichever screen AppKit picks at that moment, and
/// laying out at 1× moves text by a pixel (measured on settings-archived-page).
///
/// The render is also isolated from the real pointer and from key-window state (fix/test-flakes): this Mac's screen
/// and pointer are driven by other jobs during `make test-unit`, and an unordered window at the screen origin picked
/// up hover states whenever the pointer sat over its frame (settings-search-archive: a pop-up button drawn hovered;
/// settings-skills), and the search field's placeholder moved 1 px with the field's focus state (Library grid /
/// videos). So the window
/// - lies far outside every display (`offscreenOrigin`) and reports a pointer location outside itself;
/// - ignores mouse events and drops every pointer, tracking and cursor event it is sent;
/// - is never key or main, whatever the application does with its other windows (the references are the non-key
///   look: the window was never ordered in);
/// and `render` removes every tracking area from the view tree before each capture (no hover can start mid-capture).
final class SnapshotWindow: NSWindow {
    nonisolated static let scale: CGFloat = 2
    /// Far from any display arrangement (and from where an unordered window would sit: the main screen's origin).
    nonisolated static let offscreenOrigin = CGPoint(x: -40_000, y: -40_000)
    var fixedScale: CGFloat = SnapshotWindow.scale
    override var backingScaleFactor: CGFloat { fixedScale }

    override var isKeyWindow: Bool { false }
    override var isMainWindow: Bool { false }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: -1_000_000, y: -1_000_000) }
    /// AppKit otherwise moves the window back onto a screen (a titled window is constrained to one, and a new window
    /// is placed: measured at (320, 748) after `init` + `setContentSize`). Every frame change keeps it offscreen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        NSRect(origin: Self.offscreenOrigin, size: frameRect.size)
    }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: Self.offscreenOrigin, size: frameRect.size), display: flag)
    }
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(Self.offscreenOrigin) }
    override func setFrameTopLeftPoint(_ point: NSPoint) {
        super.setFrameOrigin(Self.offscreenOrigin)
    }

    static let pointerEvents: Set<NSEvent.EventType> = [
        .mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel, .pressure, .tabletPoint, .tabletProximity,
        .magnify, .swipe, .rotate, .gesture, .beginGesture, .endGesture, .smartMagnify,
    ]

    override func sendEvent(_ event: NSEvent) {
        if Self.pointerEvents.contains(event.type) { return }
        super.sendEvent(event)
    }

    /// Removes every tracking area in `view`'s tree: nothing in the render reacts to the pointer during a capture.
    static func disableTracking(in view: NSView) {
        for area in view.trackingAreas { view.removeTrackingArea(area) }
        for sub in view.subviews { disableTracking(in: sub) }
    }
}

@MainActor
/// `converge`: after the fixed settle, keep pumping the run loop and re-laying out until three consecutive bitmaps are
/// byte-identical (≤ 10 s). A fixed wall-clock settle is not enough under `make test-unit --parallel`: other suites
/// hold the main actor, so SwiftUI's follow-up update passes (e.g. the ⌘K list's first results, the field's measured
/// height) can still be pending when the 0.3 s window ends. Use it for views with no endless animation.
/// `focusField`: make the first text field the window's first responder before capturing. A view that focuses its
/// field in `onAppear` (the stand-in composer) otherwise races the capture under `--parallel`: the `@FocusState`
/// write lands in a later update pass, and the placeholder is drawn by the cell (unfocused) or the field editor
/// (focused) about 1 pt apart (MainWindow.normal-light failed with the placeholder alone shifted). The references are
/// the focused state.
func render<V: View>(_ view: V, look: Look, size: CGSize? = nil, window: Bool = false, converge: Bool = false,
                     focusField: Bool = false, scale: CGFloat = SnapshotWindow.scale) -> NSImage {
    DesignBundle.forceBrandAccent = true
    let root = view
        .environment(\.reduceMotionOverride, true)
        .environment(\.colorScheme, look == .light ? .light : .dark)
    let host = NSHostingView(rootView: root)
    host.appearance = look.appearance
    let style: NSWindow.StyleMask = window ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        : [.borderless]
    let win = SnapshotWindow(contentRect: CGRect(origin: SnapshotWindow.offscreenOrigin,
                                                 size: size ?? CGSize(width: 10, height: 10)),
                             styleMask: style, backing: .buffered, defer: false)
    win.fixedScale = scale
    win.ignoresMouseEvents = true
    win.acceptsMouseMovedEvents = false
    win.appearance = look.appearance
    win.contentView = host
    var fitted = size ?? host.fittingSize
    win.setContentSize(fitted)
    host.frame = CGRect(origin: .zero, size: fitted)
    host.layoutSubtreeIfNeeded()
    // Let SwiftUI settle (observation callbacks, split view column sizing).
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    // A self-sized view (no `size`) is measured again once settled: the first `fittingSize` can predate SwiftUI's
    // follow-up pass that measures wrapped (`fixedSize(vertical:)`) text, which under `--parallel` load landed 1 pt
    // taller after the capture (settings-delete-all: 372 vs 374 px). Re-fit until two measurements agree (≤ 2 s).
    if size == nil {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let again = host.fittingSize
            if again == fitted { break }
            fitted = again
            win.setContentSize(fitted)
            host.frame = CGRect(origin: .zero, size: fitted)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }
    if focusField {
        func field(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.isEditable { return f }
            return v.subviews.lazy.compactMap(field).first
        }
        if let f = field(host), !(win.firstResponder is NSText) {
            _ = win.makeFirstResponder(f)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }
    func capture() -> NSBitmapImageRep {
        SnapshotWindow.disableTracking(in: host)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((fitted.width * 2).rounded()),
                                   pixelsHigh: Int((fitted.height * 2).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        rep.size = fitted
        look.appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        return rep
    }
    var rep = capture()
    if converge {
        let deadline = Date().addingTimeInterval(10)
        var stable = 0
        while stable < 2, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let next = capture()
            stable = next.tiffRepresentation == rep.tiffRepresentation ? stable + 1 : 0
            rep = next
        }
    }
    let image = NSImage(size: fitted)
    image.addRepresentation(rep)
    return image
}

/// Renders fresh (a new hosting view and window each time) until two consecutive renders are byte-identical (≤ 4).
/// SwiftUI sizes a TextField from its own text measurement, once per hosting view: under the full parallel run that
/// measurement came out 1 pt taller now and then (Settings' search field and the Delete all field, the Library's search
/// field: the field alone taller, the rest of the layout and every glyph identical), and the view does not re-measure
/// it (invalidating the NSTextField's intrinsic size is not re-queried; measured in a probe). A second, independent
/// render is the check: in every failed run the outlier was a single render, the same views' later renders were right.
@MainActor
func renderAgreed(_ make: () -> NSImage) -> NSImage {
    var last = make()
    for _ in 0..<3 {
        let next = make()
        if next.tiffRepresentation == last.tiffRepresentation { return next }
        last = next
    }
    return last
}

@MainActor
func assertLooks<V: View>(_ name: String, size: CGSize? = nil, window: Bool = false, converge: Bool = false,
                          focusField: Bool = false, _ view: @autoclosure () -> V,
                          filePath: StaticString = #filePath, line: UInt = #line, column: UInt = #column) {
    for look in Look.allCases {
        let image = converge
            ? renderAgreed { render(view(), look: look, size: size, window: window, converge: true, focusField: focusField) }
            : render(view(), look: look, size: size, window: window, focusField: focusField)
        assertSnapshot(of: image,
                       as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(look.rawValue)",
                       fileID: #fileID, file: filePath, testName: "window", line: line, column: column)
    }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct WindowSnapshotTests {
    let fixed = Date(timeIntervalSince1970: 1_793_361_600)  // 2026-10-30

    func sampleChat(_ title: String = "Plan a weekend in Lisbon", evil: Bool = false) -> ChatSummary {
        ChatSummary(id: "c1", title: title, isEvil: evil, createdAt: fixed, updatedAt: fixed)
    }

    func row(_ chat: ChatSummary, selected: Bool = false, activity: ChatRowActivity = .idle, renaming: Bool = false,
             hover: Bool? = false) -> some View {
        ChatRow(chat: chat, selected: selected, activity: activity, renaming: renaming, pinnedHover: hover,
                menu: { AnyView(Image(systemName: "ellipsis").foregroundStyle(Color.textSecondary)) })
            .frame(width: 244)
            .padding(Spacing.space2)
            .background(Color.surfaceSidebar)
    }

    /// The render window's isolation (fix/test-flakes), with synthetic events sent to the window object only (nothing
    /// is posted to the system, the screen and the real pointer are not touched): never key or main, outside every
    /// display, the pointer reported outside it, and pointer / tracking events dropped before AppKit dispatches them.
    @Test func renderWindowIgnoresThePointerAndKeyState() {
        final class Probe: NSView {
            var events: [NSEvent.EventType] = []
            override func mouseDown(with event: NSEvent) { events.append(event.type) }
            override func mouseMoved(with event: NSEvent) { events.append(event.type) }
            override func mouseEntered(with event: NSEvent) { events.append(event.type) }
        }
        let rect = CGRect(origin: SnapshotWindow.offscreenOrigin, size: CGSize(width: 100, height: 100))
        let win = SnapshotWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        let probe = Probe(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        win.contentView = probe
        win.setContentSize(CGSize(width: 120, height: 120))
        win.makeKey()
        #expect(!win.isKeyWindow && !win.isMainWindow && !win.canBecomeKey && !win.canBecomeMain)
        #expect(NSScreen.screens.allSatisfy { !$0.frame.intersects(win.frame) }, "\(win.frame)")
        #expect(!probe.bounds.contains(probe.convert(win.mouseLocationOutsideOfEventStream, from: nil)))
        for type in [NSEvent.EventType.leftMouseDown, .mouseMoved] {
            win.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: 50, y: 50), modifierFlags: [], timestamp: 0,
                                             windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: 1)!)
        }
        #expect(probe.events.isEmpty, "\(probe.events)")
        #expect([.mouseMoved, .mouseEntered, .mouseExited, .cursorUpdate, .leftMouseDown, .scrollWheel]
            .allSatisfy { SnapshotWindow.pointerEvents.contains($0) })
    }

    @Test func chatRowStates() {
        let c = sampleChat()
        assertLooks("ChatRow.default", row(c))
        assertLooks("ChatRow.hover", row(c, hover: true))
        assertLooks("ChatRow.selected", row(c, selected: true))
        assertLooks("ChatRow.streaming", row(c, activity: .streaming))
        assertLooks("ChatRow.renaming", row(c, renaming: true))
        assertLooks("ChatRow.evil", row(sampleChat("Unfiltered take", evil: true)))
        assertLooks("ChatRow.untitled", row(sampleChat("")))
        // "deleting" = the confirmation popover's content (popovers are separate windows; the row is unchanged).
        assertLooks("ChatRow.deleting", DeleteConfirmation(title: c.title, onConfirm: {}, onCancel: {})
            .background(Color.surfaceRaised))
    }

    @Test func emptyStateNormal() {
        let view = EmptyStateView(headline: CopyKey("empty.headline.4"),
                                  suggestions: SuggestionProvider.suggestions(enabled: [.chat], seed: 1),
                                  onSuggestion: { _ in }) {
            StandInComposer(context: ComposerSlotContext(text: .constant(""), send: { _, _, _ in }, isEmptyState: true))
        }
        .background(Color.surfaceCanvas)
        assertLooks("EmptyState.normal", size: CGSize(width: 920, height: 640), view)
    }

    func window(width: CGFloat) throws -> some View {
        let service = try ChatListService.inMemory()
        for (i, t) in ["Plan a weekend in Lisbon", "Explain recursion simply", "Email to the landlord"].enumerated() {
            _ = try service.create(title: t)
            _ = i
        }
        let state = WindowState(service: service, enabledPacks: [.chat], seed: 4)
        state.activate()
        return MainWindow(state: state)
    }

    /// The sidebar on its own: offscreen `cacheDisplay` does not draw the macOS 26 glass sidebar pane inside
    /// NavigationSplitView (the MainWindow snapshots show it blank; the AT-001 probe's screencapture shows it).
    @Test func sidebarContent() async throws {
        let service = try ChatListService.inMemory()
        let pinned = try service.create(title: "Recipes to try")
        try service.setPinned(pinned.id, true)
        for t in ["Plan a weekend in Lisbon", "Explain recursion simply", ""] { _ = try service.create(title: t) }
        let state = WindowState(service: service, enabledPacks: [.chat], seed: 4)
        state.activate()
        for _ in 0..<200 where state.sidebar.count < 4 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.sidebar.count == 4)
        assertLooks("Sidebar.content", size: CGSize(width: 260, height: 560),
                    SidebarView(state: state, onSearch: {}).environment(\.locale, Locale(identifier: "en_US")))
    }

    @Test func mainWindowNormalAndNarrow() throws {
        // Sidebar dates are "now" (Today section), so the snapshot is stable across days.
        let normal = try window(width: 1180)
        assertLooks("MainWindow.normal", size: CGSize(width: 1180, height: 820), window: true, converge: true,
                    focusField: true, normal)
        let narrow = try window(width: 860)
        assertLooks("MainWindow.narrow", size: CGSize(width: 860, height: 700), window: true, converge: true,
                    focusField: true, narrow)
    }
}
}  // extension WindowSuites
