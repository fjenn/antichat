// Q-015 r4 (M9.T03): `ScrollViewHitTest.refine`, the AntiChatApplication accessibility hit-test workaround. Only an
// answer that ended on a SwiftUI hosting scroll view changes, and only to a deeper element that a hosting view above
// it resolves. Everything else passes through, and AppKit's own scroll views are never re-asked. The end-to-end leg
// is XCUITest (ImageJobCardTests.testStopWithinOneSecond clicks the transcript card's Stop with `click()`).
import AppKit
import Testing
@testable import AntiChatUI

/// Stands in for SwiftUI's private `HostingScrollView` (the check is by class name).
private final class FakeHostingScrollView: NSScrollView {}

/// Stands in for an `NSHostingView`: answers a fixed element and counts the questions.
private final class FakeHostingView: NSView {
    nonisolated(unsafe) var answer: Any?
    nonisolated(unsafe) var asked = 0
    /// nil: AppKit's own children.
    nonisolated(unsafe) var children: [Any]?
    override func accessibilityChildren() -> [Any]? { children ?? super.accessibilityChildren() }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        asked += 1
        return answer
    }
}

@MainActor @Suite(.isolatedSettings) struct ScrollViewHitTestTests {
    let point = NSPoint(x: 40, y: 40)

    @Test func otherAnswersPassThrough() {
        let element = NSObject()
        #expect(ScrollViewHitTest.refine(element, at: point) as? NSObject === element)
        #expect(ScrollViewHitTest.refine(nil, at: point) == nil)
    }

    @Test func appKitScrollViewsAreNeverReAsked() {
        let host = FakeHostingView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        host.answer = NSObject()
        let scroll = NSScrollView(frame: host.bounds)
        host.addSubview(scroll)
        #expect(ScrollViewHitTest.refine(scroll, at: point) as? NSScrollView === scroll)
        #expect(host.asked == 0)
    }

    @Test func hostingScrollViewResolvesToTheHostingViewsDeeperElement() {
        let host = FakeHostingView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let button = NSObject()
        host.answer = button
        let scroll = FakeHostingScrollView(frame: host.bounds)
        host.addSubview(scroll)
        #expect(ScrollViewHitTest.isSwiftUIHostingScrollView(scroll))
        #expect(ScrollViewHitTest.refine(scroll, at: point) as? NSObject === button)
        #expect(host.asked == 1)
    }

    @Test func noDeeperAnswerKeepsTheScrollView() {
        let outer = FakeHostingView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let inner = FakeHostingView(frame: outer.bounds)
        outer.addSubview(inner)
        let scroll = FakeHostingScrollView(frame: inner.bounds)
        inner.addSubview(scroll)
        // The scroll view itself, an ancestor of it, or nothing: none is deeper.
        inner.answer = scroll
        outer.answer = inner
        #expect(ScrollViewHitTest.refine(scroll, at: point) as? NSScrollView === scroll)
        inner.answer = nil
        outer.answer = nil
        #expect(ScrollViewHitTest.refine(scroll, at: point) as? NSScrollView === scroll)
    }

    @Test func theNearestHostingViewWithADeeperAnswerWins() {
        let outer = FakeHostingView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let inner = FakeHostingView(frame: outer.bounds)
        outer.addSubview(inner)
        let scroll = FakeHostingScrollView(frame: inner.bounds)
        inner.addSubview(scroll)
        let element = NSObject()
        inner.answer = nil  // a split view column's own hosting view that resolves nothing
        outer.answer = element
        #expect(ScrollViewHitTest.refine(scroll, at: point) as? NSObject === element)
        #expect(inner.asked == 1 && outer.asked == 1)
    }

    private func element(_ frame: NSRect, children: [Any] = []) -> NSAccessibilityElement {
        let e = NSAccessibilityElement()
        e.setAccessibilityElement(true)
        e.setAccessibilityFrame(frame)
        e.setAccessibilityChildren(children)
        return e
    }

    /// Q-015 r6: an overlay SwiftUI draws over the scroll view (the picture viewer over the transcript) wins over the
    /// hosting view's own answer (an element of the content under it): its topmost element under the point.
    @Test func anOverlayAboveTheScrollViewResolvesToItsElementUnderThePoint() {
        let host = FakeHostingView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let scroll = FakeHostingScrollView(frame: host.bounds)
        host.addSubview(scroll)
        let underneath = NSObject()
        host.answer = underneath
        let reveal = element(NSRect(x: 30, y: 30, width: 20, height: 20))
        let other = element(NSRect(x: 100, y: 30, width: 20, height: 20))
        let viewer = element(NSRect(x: 0, y: 0, width: 200, height: 200), children: [other, reveal])
        host.children = [scroll, viewer]
        #expect(ScrollViewHitTest.refine(scroll, at: point) as? NSObject === reveal)
        // Between the viewer's controls: the viewer itself, never the content under it.
        #expect(ScrollViewHitTest.refine(scroll, at: NSPoint(x: 80, y: 120)) as? NSObject === viewer)
        #expect(host.asked == 0)
    }

    /// Without an overlay the walk ends on the scroll view, and the hosting view's answer stays (the earlier tests).
    @Test func withoutAnOverlayTheHostingViewsAnswerStays() {
        let host = FakeHostingView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let scroll = FakeHostingScrollView(frame: host.bounds)
        host.addSubview(scroll)
        let button = NSObject()
        host.answer = button
        host.children = [scroll, element(NSRect(x: 150, y: 150, width: 20, height: 20))]
        #expect(ScrollViewHitTest.refine(scroll, at: point) as? NSObject === button)
    }

    /// Q-015 r6 (P73): SwiftUI answered with the reply's whole-text static element drawn behind the Markdown view;
    /// the citation pill in a later sibling under the point wins. A static text with nothing on top, and a button
    /// answer, stay as they are.
    @Test func aStaticTextBehindALaterSiblingResolvesIntoIt() {
        let reply = element(NSRect(x: 0, y: 0, width: 200, height: 100))
        let text = element(reply.accessibilityFrame())
        text.setAccessibilityRole(.staticText)
        text.setAccessibilityParent(reply)
        let pill = element(NSRect(x: 20, y: 20, width: 60, height: 16))
        pill.setAccessibilityRole(.button)
        let markdown = NSAccessibilityElement()
        markdown.setAccessibilityElement(false)  // a `.contain` group: not an element itself
        markdown.setAccessibilityFrame(NSRect(x: 0, y: 0, width: 180, height: 100))
        markdown.setAccessibilityChildren([pill])
        reply.setAccessibilityChildren([text, markdown])
        #expect(ScrollViewHitTest.refine(text, at: NSPoint(x: 30, y: 25)) as? NSObject === pill)
        #expect(ScrollViewHitTest.refine(text, at: NSPoint(x: 150, y: 80)) as? NSObject === text)
        #expect(ScrollViewHitTest.refine(pill, at: NSPoint(x: 30, y: 25)) as? NSObject === pill)
    }
}
