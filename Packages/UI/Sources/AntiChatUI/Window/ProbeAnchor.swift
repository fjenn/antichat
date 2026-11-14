// `probeID(_:)`: the accessibility identifier XCUITest queries, plus (DEBUG only) a zero-cost AppKit anchor so the
// in-process window probe (App/AntiChat/WindowProbe.swift, AT-001 while XCUITest is blocked by Q-015) can read the
// element's real window frame and presence. SwiftUI builds its accessibility tree only for a live AX client, so
// the probe cannot read it from inside the app; the anchor gives it the same geometry.
// R65 (VQ-M10 S-24 / S-10 regression): SwiftUI hosts the anchor in a platform view (`AppKitPlatformViewHost`) stacked
// above the SwiftUI drawing, and in the app's window that host answered AppKit's hit test for its whole frame although
// the anchor itself returns nil, so a click on a probed button went to whichever anchor host was stacked last (the
// approval card's Deny / Always allow, the Sources button) and the button never fired. `.allowsHitTesting(false)` takes
// the anchor out of SwiftUI's hit testing, so its host no longer answers (ApprovalCardActivationTests).
import AppKit
import SwiftUI

public extension View {
    /// Accessibility identifier + probe anchor (DEBUG).
    func probeID(_ id: String) -> some View {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        accessibilityIdentifier(id).background(ProbeAnchor(id: id).allowsHitTesting(false))
        #else
        accessibilityIdentifier(id)
        #endif
    }

    /// The probe anchor alone (DEBUG), for a view whose accessibility identifier is already set: a second
    /// `probeID` would replace the identifier XCUITest queries (Q-015 catch-up: `activityLine`).
    @ViewBuilder func probeAnchor(_ id: String) -> some View {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        background(ProbeAnchor(id: id).allowsHitTesting(false))
        #else
        self
        #endif
    }
}

#if DEBUG || ANTICHAT_PERF_HARNESS
@MainActor
public enum UIProbeRegistry {
    final class Box { weak var view: NSView? ; init(_ v: NSView) { view = v } }
    static var anchors: [String: [Box]] = [:]

    /// Live frames (window coordinates, origin bottom-left) of every on-screen anchor with `id`.
    public static func frames(_ id: String, in window: NSWindow) -> [CGRect] {
        (anchors[id] ?? []).compactMap { box in
            // The anchor itself is always hidden (AnchorView): only its ancestors say whether the control is shown.
            guard let v = box.view, v.window === window, !(v.superview?.isHiddenOrHasHiddenAncestor ?? true),
                  v.bounds.width > 0.5, v.bounds.height > 0.5 else { return nil }
            return v.convert(v.bounds, to: nil)
        }
    }

    public static func frame(_ id: String, in window: NSWindow) -> CGRect? { frames(id, in: window).first }

    /// Every live anchor view by id (probe diagnostics).
    public static var anchorViews: [String: [NSView]] { anchors.mapValues { $0.compactMap(\.view) } }

    /// Ids with a live anchor matching `prefix`.
    public static func ids(prefix: String, in window: NSWindow) -> [String] {
        anchors.keys.filter { $0.hasPrefix(prefix) && frame($0, in: window) != nil }.sorted()
    }

    /// The id each live anchor view is registered under (Q-015 r6: `register` runs from every `updateNSView`, i.e. for
    /// every anchor in every SwiftUI update; scanning all anchors there made each update O(anchors²) in the samples).
    private static var registered: [ObjectIdentifier: String] = [:]

    static func register(_ id: String, _ v: NSView) {
        let key = ObjectIdentifier(v)
        // Unchanged (the common case). The membership check covers an identifier reused by a new view.
        if registered[key] == id, anchors[id]?.contains(where: { $0.view === v }) == true { return }
        // A reused List/Form cell keeps its anchor view but shows another row: drop it from its old id first.
        if let other = registered[key], other != id, let boxes = anchors[other] {
            anchors[other] = boxes.filter { $0.view !== v && $0.view != nil }
        }
        registered[key] = id
        var list = (anchors[id] ?? []).filter { $0.view != nil }
        if !list.contains(where: { $0.view === v }) { list.append(Box(v)) }
        anchors[id] = list
    }
}

private struct ProbeAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let v = AnchorView()
        UIProbeRegistry.register(id, v)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { UIProbeRegistry.register(id, v) }

    /// Q-015 r3: a shown anchor is an NSView above the SwiftUI content it measures, and the accessibility hit test
    /// (VoiceOver's mouse/trackpad commander, Switch Control point scanning, XCUITest's "hittable") resolved every point
    /// over a probed view to the anchor — ignored, so to its container — never to the control: buttons inside reply
    /// cards and Settings rows were "Not hittable" and the audit said "Action is missing". Hidden, AppKit skips it for
    /// both hit tests while `convert(_:to:)` still gives the frame the probes read.
    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
        override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
        override var isHidden: Bool { get { true } set {} }
    }
}
#endif
