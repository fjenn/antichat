// Owner report 2026-11-16 ("I can't scroll up in the chats… same for the sidebar"): with the notifications explainer
// shown above the composer, the whole split view was laid out taller than the window and centred in it (installed
// build, read through accessibility: window 1180 × 1032, split view 1180 × 1551 at y −233). The top of the sidebar
// and of the transcript sat above the window, the composer and the sidebar footer below it; scrolling up ended at an
// offset that was still off screen. The banner's sentence pinned its ideal height (`fixedSize(vertical:)`), so the
// column's minimum-size query (a zero proposal) got it wrapped a few letters per line. Same defect as F6
// (OfflineChipNoticeTests).
//   cd Packages/UI && swift test --filter ExplainerBannerWindowHeightTests
import AppKit
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import SwiftUI
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct ExplainerBannerWindowHeightTests {
    private func minimumHeight<V: View>(_ view: V) -> CGFloat {
        _ = NSApplication.shared
        MinimumSizeProbe.minimum = .zero
        let host = NSHostingView(rootView: MinimumSizeProbe { view }.frame(width: 760))
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 200)
        host.layoutSubtreeIfNeeded()
        return MinimumSizeProbe.minimum.height
    }

    @Test func notificationsExplainerDoesNotInflateTheMinimumHeight() {
        PermissionExplainers.shared.pending = .notifications
        defer { PermissionExplainers.shared.pending = nil }
        let h = minimumHeight(NotificationExplainerBanner())
        // The row at its real width is ~45 pt; before the fix the zero proposal answered over 1,000 pt.
        #expect(h > 0 && h < 120, "minimum height \(h)")
        // At a real, narrow width the sentence still wraps (taller than at the reading width), it is not cut short.
        func fitting(_ width: CGFloat) -> CGFloat {
            NSHostingView(rootView: NotificationExplainerBanner().frame(width: width)).fittingSize.height
        }
        #expect(fitting(420) > fitting(760) + 10, "fitting \(fitting(420)) at 420, \(fitting(760)) at 760")
    }

    @Test func locationExplainerDoesNotInflateTheMinimumHeight() {
        let h = minimumHeight(LocationExplainerBanner())
        #expect(h > 0 && h < 120, "minimum height \(h)")
    }

    /// The window itself: a docked chat with the explainer up; the split view stays inside the window.
    @Test func splitViewStaysInsideTheWindowWithTheExplainerShown() throws {
        _ = NSApplication.shared
        let service = try ChatListService.inMemory()
        let chat = try service.create(title: "Tallest building")
        let state = WindowState(service: service, enabledPacks: [.chat], seed: 4)
        state.activate()
        state.open(.chat(chat.id))
        #expect(state.isDocked)
        PermissionExplainers.shared.pending = .notifications
        defer { PermissionExplainers.shared.pending = nil }

        let host = NSHostingView(rootView: MainWindow(state: state).environment(\.reduceMotionOverride, true))
        let size = CGSize(width: 1180, height: 820)
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                           styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        defer { win.close() }

        func splits(_ v: NSView) -> [NSSplitView] { (v as? NSSplitView).map { [$0] } ?? v.subviews.flatMap(splits) }
        let split = try #require(splits(host).first, "no split view in the window")
        let frame = split.convert(split.bounds, to: nil)
        #expect(win.frame.height < 900, "window \(win.frame.size)")
        #expect(frame.height <= win.frame.height + 1, "split view \(frame) in a window of \(win.frame.size)")
        #expect(frame.minY >= -1, "split view \(frame) starts below the window")
        // The columns no longer answer with their content's minimum size; the window still has its own minimum.
        win.setContentSize(CGSize(width: 200, height: 200))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let content = win.contentRect(forFrameRect: win.frame).size
        #expect(content.width >= Layout.windowMin.width && content.height >= Layout.windowMin.height, "content \(content)")
        let shrunk = split.convert(split.bounds, to: nil)
        #expect(shrunk.height <= win.frame.height + 1 && shrunk.minY >= -1, "split view \(shrunk) in \(win.frame.size)")
    }
}
