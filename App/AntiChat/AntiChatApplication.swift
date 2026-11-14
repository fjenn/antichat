// AntiChatApplication (Q-015 r4, M9.T03): the app's principal class. It exists only to work around a SwiftUI
// accessibility hit-test defect inside the app's scroll views (`ScrollViewHitTest`, docs/prd/M9-T03-hit-test-feedback.md).
// It overrides `accessibilityHitTest(_:)` and nothing else: event dispatch (`sendEvent`), mouse hit testing and every
// other NSApplication behaviour are unchanged. `PrincipalClassTests` (integration) keeps it that way.
// `Entry.main` creates it before anything touches `NSApplication.shared`.
import AntiChatUI
import AppKit

@objc(AntiChatApplication)
final class AntiChatApplication: NSApplication {
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        // AppKit asks on the main thread; the override is nonisolated only because NSAccessibility's is.
        nonisolated(unsafe) var result = super.accessibilityHitTest(point)
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // A/B switch for checking whether the workaround is still needed (XCUITest with and without it).
        if ProcessInfo.processInfo.environment["ANTICHAT_AX_HIT_REFINE"] == "0" { return result }
        #endif
        MainActor.assumeIsolated { result = ScrollViewHitTest.refine(result, at: point) }
        return result
    }
}
