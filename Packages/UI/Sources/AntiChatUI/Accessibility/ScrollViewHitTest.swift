// ScrollViewHitTest (Q-015 r4, M9.T03): works around an accessibility hit-test defect in the app's SwiftUI scroll
// views.
//
// The defect: in the app's window, inside a SwiftUI `ScrollView` (or a grouped `Form`, which is one), the window's
// accessibility hit test stops at the scroll view. AppKit finds the deepest NSView under the point (SwiftUI's private document view) and
// asks it, and that view answers with its scroll view (AXScrollArea) instead of descending into the SwiftUI elements
// it hosts. The window's NSHostingView resolves the same point to the right element.
//
// Impact: every control in the chat transcript is "not hittable" (reply cards' Cancel / Stop, plan card chips,
// message actions), as is every control in the composer's scroll view and in Settings' Forms. VoiceOver's
// mouse-follow, Switch Control point scanning, Accessibility Inspector and XCUITest all land on the scroll area.
//
// Measurements: docs/prd/M9-T03-hit-test-feedback.md. A standalone ScrollView does not show the defect, so its trigger
// in the app's window is not isolated yet and no Feedback is filed. The app's principal class (`AntiChatApplication`)
// passes its `accessibilityHitTest(_:)` result through `refine`. Nothing else changes: no event dispatch, no mouse
// hit testing (`NSView.hitTest`), and no other accessibility attribute. The workaround is on in Release too, because
// VoiceOver users meet the defect there. Remove it once `ANTICHAT_AX_HIT_REFINE=0` (DEBUG) hit-tests the
// transcript's buttons correctly (the A/B in the doc).
import AppKit

@MainActor
public enum ScrollViewHitTest {
    /// `result` (an accessibility hit test's answer for `point`, screen coordinates), unless it is a SwiftUI hosting
    /// scroll view whose window's content view resolves `point` to a deeper element. Then that element.
    public static func refine(_ result: Any?, at point: NSPoint) -> Any? {
        textBehindRefined(scrollRefined(result, at: point), at: point)
    }

    /// Q-015 r6 (WebSearch: `citation.1` not hittable): SwiftUI answered with a static text drawn *behind* its later
    /// siblings (the reply's whole-text element `assistantText`, a background of the Markdown view, over which the
    /// citation pills sit). A later sibling (drawn on top) whose subtree holds an element under the point wins.
    /// Only for a static text answer: a control or an overlay's answer is never second-guessed.
    static func textBehindRefined(_ result: Any?, at point: NSPoint) -> Any? {
        guard let text = result as? NSObject, !(text is NSView),
              ((text as AnyObject).accessibilityRole?() ?? nil) == .staticText,
              let parent = (text as AnyObject).accessibilityParent?() as? NSObject,
              let siblings = (parent as AnyObject).accessibilityChildren?() ?? nil,
              let index = siblings.firstIndex(where: { ($0 as AnyObject) === text }) else { return result }
        var budget = 2_000
        for case let kid as NSObject in siblings[(index + 1)...].reversed() {
            guard let frame = (kid as AnyObject).accessibilityFrame?(), frame.contains(point) else { continue }
            if let hit = deepestElement(kid, at: point, depth: 0, budget: &budget), hit !== kid || (kid as AnyObject).isAccessibilityElement?() == true {
                return hit
            }
        }
        return result
    }

    static func scrollRefined(_ result: Any?, at point: NSPoint) -> Any? {
        guard let scroll = result as? NSScrollView, isSwiftUIHostingScrollView(scroll) else { return result }
        // Q-015 r6: an overlay drawn over the scroll view by SwiftUI (the picture viewer over the transcript) has no
        // NSView of its own, and the hosting view's own hit test answered with an element of the transcript under it
        // (or the scroll area): the viewer's toolbar (Show in Finder, Copy, Zoom) was not hittable. Walk the nearest
        // hosting view's accessibility tree, topmost (last) child first, to the deepest element under the point.
        if let host = nearestHostingView(above: scroll) {
            var budget = 4_000
            if let walked = deepestElement(host, at: point, depth: 0, budget: &budget), walked !== scroll, walked !== host,
               !((walked as? NSView).map { scroll.isDescendant(of: $0) } ?? false) {
                return walked
            }
        }
        // The hosting views above the scroll view, nearest first (a NavigationSplitView column has its own, inside
        // the window's): the first one that resolves the point below the scroll view wins.
        var view = scroll.superview
        while let v = view {
            if isHostingView(v), let deeper = v.accessibilityHitTest(point) as? NSObject, deeper !== scroll,
               !(deeper is NSView && (deeper as? NSView).map({ scroll.isDescendant(of: $0) }) == true) {
                return deeper
            }
            view = v.superview
        }
        // Q-015 r6: a platform control hosted in the scroll view (a SwiftUI `Menu` is an NSPopUpButton: the reply's
        // ⋯ `action.more`) is not reached through the hosting views' answer, which stays on the scroll area. The
        // control that a click at the point would reach is the answer.
        return platformControl(in: scroll, at: point) ?? result
    }

    static func nearestHostingView(above view: NSView) -> NSView? {
        var v = view.superview
        while let candidate = v {
            if isHostingView(candidate) { return candidate }
            v = candidate.superview
        }
        return nil
    }

    /// The deepest accessibility element under `point` (screen coordinates) in `element`'s subtree. Children are tried
    /// last first (SwiftUI lists an overlay after the content it covers); an ignored container (no element of its own)
    /// none of whose children holds the point is passed over for the siblings below it. nil: nothing under the point.
    static func deepestElement(_ element: NSObject, at point: NSPoint, depth: Int, budget: inout Int) -> NSObject? {
        budget -= 1
        guard depth < 64, budget > 0 else { return nil }
        if let v = element as? NSView, v.isHiddenOrHasHiddenAncestor { return nil }
        let kids = ((element as AnyObject).accessibilityChildren?() ?? nil) ?? []
        for case let kid as NSObject in kids.reversed() {
            guard let frame = (kid as AnyObject).accessibilityFrame?(), frame.width > 0, frame.height > 0,
                  frame.contains(point) else { continue }
            if let hit = deepestElement(kid, at: point, depth: depth + 1, budget: &budget) { return hit }
        }
        let isElement = (element as AnyObject).isAccessibilityElement?() ?? false
        return isElement ? element : nil
    }

    /// The AppKit control (NSControl, an accessibility element) that the mouse hit test finds at `point` (screen
    /// coordinates) inside `scroll`'s document view, if any.
    static func platformControl(in scroll: NSScrollView, at point: NSPoint) -> Any? {
        guard let window = scroll.window, let doc = scroll.documentView, let parent = doc.superview else { return nil }
        let local = parent.convert(window.convertPoint(fromScreen: point), from: nil)
        var v = doc.hitTest(local)
        while let view = v, view !== scroll {
            if let control = view as? NSControl, control.isAccessibilityElement(), !control.isHiddenOrHasHiddenAncestor {
                return control.accessibilityHitTest(point) ?? control
            }
            v = view.superview
        }
        return nil
    }

    static func isHostingView(_ view: NSView) -> Bool {
        String(describing: type(of: view)).contains("HostingView")
    }

    /// A SwiftUI `ScrollView` / grouped `Form` (the private class `SwiftUI.HostingScrollView`). AppKit's own scroll
    /// views (NSTextView's, NSTableView's) never match, so their hit tests are untouched.
    public static func isSwiftUIHostingScrollView(_ view: NSScrollView) -> Bool {
        String(describing: type(of: view)).contains("HostingScrollView")
    }
}
