// F6 (round 66, vq-m7 s25-offline-chip): turning on Offline only with a Web search chip in the composer broke the
// whole window. The notice under the composer (OfflineChipNotice) pinned its text to its ideal height
// (`fixedSize(vertical:)`), so the window's minimum-size query (a zero proposal) got the text wrapped one word per line,
// some 1,200 pt; the split view grew past the window and was centred in it: the sidebar's "Chats" row sat under the
// traffic lights, New chat / Search / Library / Projects above the window and the Settings footer below it.
//   make test-unit FILTER=OfflineChipNoticeTests
import AppKit
import AntiChatTools
import SwiftUI
import Testing
@testable import AntiChatUI

/// Records the size its child answers to a minimum-size query (the zero proposal NSHostingView.minSize sends).
struct MinimumSizeProbe: Layout {
    nonisolated(unsafe) static var minimum: CGSize = .zero
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        Self.minimum = subviews.first?.sizeThatFits(.zero) ?? .zero
        return subviews.first?.sizeThatFits(proposal) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, proposal: proposal) }
    }
}

@MainActor
@Suite(.serialized, .isolatedSettings) struct OfflineChipNoticeTests {
    @Test(arguments: [WebSearchAvailability.State.offlineOnly, .noNetwork])
    func noticeDoesNotInflateTheWindowMinimumHeight(_ cause: WebSearchAvailability.State) {
        _ = NSApplication.shared
        MinimumSizeProbe.minimum = .zero
        let host = NSHostingView(rootView: MinimumSizeProbe { OfflineChipNotice(cause: cause) }.frame(width: 700))
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 200)
        host.layoutSubtreeIfNeeded()
        // One footnote line is ~16 pt; before the fix the zero proposal answered well over 500 pt.
        #expect(MinimumSizeProbe.minimum.height < 60, "minimum \(MinimumSizeProbe.minimum)")
        // At its real width the notice still shows its whole text on one line.
        #expect(host.fittingSize.height < 40, "fitting \(host.fittingSize)")
    }
}
