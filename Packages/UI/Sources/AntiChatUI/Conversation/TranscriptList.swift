// TranscriptList (M1.T07 step 4; IS-7): a message column in a `ScrollView` (newest rows eager, older history lazy) anchored at
// the bottom. Auto-scroll follows new content only while the view is at the bottom; any upward scroll detaches
// it and shows JumpToBottom. Rows are drawn by the caller (M1.T06 UserBubble / AssistantMessageView); M1.T07's
// default row is plain text.
import AntiChatDesign
import AntiChatHarness
import AppKit
import QuartzCore
import SwiftUI

#if DEBUG
/// fix/selection-hang-2: logs a transcript column whose width oscillates (the self-sustaining layout loop of the
/// XCUITest r4/r5 hangs) with the scroller style, so the next hang names its trigger. Logging only, never state.
@MainActor
enum TranscriptWidthWatch {
    private static var second = (start: Date.distantPast, count: 0, widths: Set<Int>())
    private static var lastLog = Date.distantPast
    /// Width changes seen (tests).
    static var changes = 0

    static func changed(to width: CGFloat) {
        changes += 1
        let now = Date()
        if now.timeIntervalSince(second.start) > 1 { second = (now, 0, []) }
        second.count += 1
        second.widths.insert(Int(width.rounded()))
        guard second.count > 10, now.timeIntervalSince(lastLog) > 5 else { return }
        lastLog = now
        let style = NSScroller.preferredScrollerStyle == .legacy ? "legacy" : "overlay"
        NSLog("TranscriptWidthWatch: column width changed %d times in 1 s among %@ (scrollers: %@)",
              second.count, second.widths.sorted().description, style)
    }
}
#endif

struct TranscriptList<Item: Identifiable & Equatable, Row: View>: View where Item.ID: Sendable {
    let items: [Item]
    let startDate: Date?
    /// M1.T24: the find bar's current match; the list scrolls it into view when it changes.
    var scrollTarget: Item.ID? = nil
    /// M9.T05 (NFR-U2): rows the newest change appended whose frame has not committed yet (a send's user message and
    /// pending reply until the ack frame is drawn; `ConversationModel.unsettledRows`). They join the eager section
    /// without moving the eager/lazy boundary; the boundary catches up in the next frame.
    var unsettledRows: Int = 0
    @ViewBuilder var row: (Item) -> Row
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)

    /// Distance from the bottom (pt) within which the view counts as "at the bottom".
    static var attachThreshold: CGFloat { 24 }
    /// The newest rows laid out eagerly (VStack); older ones lazily. More than a screen of the latest turns.
    /// fix/u5-renderer: was 60. In an eager VStack every row's views are re-placed and re-dirtied whenever the
    /// streaming reply grows, so each reveal tick cost grew with the chat (RendererTickCostTests: a reply streaming
    /// under 60 finished replies 56–85 ms per tick vs 3 ms in a fresh chat; with 8 eager rows 4.8 ms).
    static var eagerTail: Int { 8 }
    /// fix/u5-renderer-4: rows move from the eager tail to the lazy stack `splitStep` at a time, not one per
    /// appended row. A moved row gets a new parent, so its views are built again (MarkdownView parse, text layout,
    /// selection overlays) and the lazy stack re-estimates: with a split that followed every append, every send in a
    /// long chat rebuilt older replies in the first passes of the new reply (AT-008 long chat: 100–190 ms passes in
    /// its first 2 s; `TranscriptMeasureTests`). The eager tail holds `eagerTail`…`eagerTail + splitStep − 1` rows; a
    /// larger step moves rows less often but every eager finished row adds to each reveal tick (RendererTickCostTests
    /// long chat: 4.8 ms per tick with 8 eager rows, 6.5–7.2 ms with 13), so the step is half a tail.
    static var splitStep: Int { 4 }
    /// Rows `unsettledRows` may hold in the eager section (a send adds 2); more moves the boundary at once.
    static var maxUnsettledRows: Int { 4 }

    /// M9.T05 (NFR-U2 <= 16 ms) × fix/u5-renderer-4: where the lazy section ends. The boundary moves in `splitStep`
    /// steps, and while a send's rows are unsettled it is computed as if they were not there yet, so a step that a
    /// send would trigger happens in the frame after the ack instead of the ack frame itself.
    static func lazyCount(items: Int, unsettled: Int) -> Int {
        let held = (1...maxUnsettledRows).contains(unsettled) ? min(unsettled, items) : 0
        return max(0, (items - held - eagerTail) / splitStep * splitStep)
    }
    static func lazyCount(_ count: Int) -> Int { lazyCount(items: count, unsettled: 0) }

    /// M9.T05 (NFR-U11 "opening a 500-turn chat: latest screen rendered ≤ 500 ms"): the rows a chat's first frame
    /// lays out — the newest ones, more than a window of them. The older history joins the lazy section in the frame
    /// after the first one has committed (`historyShown`). Before, the first frame of the 1,000-message chat placed a
    /// lazy stack of ~990 rows (ForEach / LazyHVStack length estimates over every row, on every settling pass of the
    /// bottom-anchored scroll view): ~270 ms of NSHostingView.layout in the T05 perf-build profile.
    static var openingRows: Int { 24 }

    /// Where the rows on screen start: `openingRows` from the end until the history is shown.
    static func firstShown(items: Int, historyShown: Bool) -> Int {
        historyShown ? 0 : max(0, items - openingRows)
    }

    @State private var historyShown = false
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var detached = false
    /// When the column's width last changed (not observed: written from a geometry callback, read in the scroll one).
    @State private var widthMark = WidthChangeMark()
    /// When the reader last moved the offset up (not observed, as `widthMark`).
    @State private var readerMark = WidthChangeMark()

    var body: some View {
        ScrollView {
            // fix/selection-hang-2: the rows a reader is at (the newest `eagerTail`) are a plain VStack; only older
            // history is lazy. With every row in a LazyVStack, XCUITest r4/r5 hung (testEditGeneratedImage,
            // testVersionsKept, testVersionRailListsVersions; queue): each layout pass enqueued another
            // `LazyLayoutCacheItem.AllItemsPhaseMutation`, whose pass re-updated every selectable Text's SelectionOverlay,
            // whose NSTextField invalidation laid out again — one never-ending flushTransactions, the autorelease pool
            // never drained (1.4M NSAppearance objects, 3 GB in 3 min). With these rows eager the same tests ran without
            // a hang and the footprint stayed ~600 MB.
            VStack(alignment: .leading, spacing: Layout.messageGap) {
                if let startDate { StartSeparator(date: startDate) }
                let first = Self.firstShown(items: items.count, historyShown: historyShown || scrollTarget != nil)
                let split = first + Self.lazyCount(items: items.count - first, unsettled: unsettledRows)
                if split > first {
                    LazyVStack(alignment: .leading, spacing: Layout.messageGap) {
                        ForEach(items[first..<split]) { item in
                            row(item).id(item.id)
                        }
                    }
                }
                ForEach(items[split...]) { item in
                    row(item).id(item.id)
                }
            }
            .frame(maxWidth: readingWidth)
            .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
            .accessibilityLabel(Text(CopyKey("a11y.transcript")))  // Q-015 r5 audit: the column group had no description
            .probeID("transcriptColumn")  // M1.T23 AT-101 probe: the reading width
            .padding(.horizontal, Spacing.space6)
            .padding(.vertical, Spacing.space6)
            .frame(maxWidth: .infinity)
            #if DEBUG
            // fix/selection-hang-2 diagnostics: a column whose width keeps changing is the layout loop behind the
            // XCUITest hangs. Logs (never stores) when it changes more than 10 times in a second.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { TranscriptWidthWatch.changed(to: $0) }
            #endif
        }
        .scrollPosition($position)
        .onAppear {
            // M9.T05 (NFR-U11): the history joins once the opening frame is on screen (a CA completion block runs
            // after that frame's commit; a main-queue job would run before it, in the same frame).
            guard !historyShown else { return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { historyShown = true } }
            CATransaction.commit()
        }
        // fix/u5-renderer: the window's hosting view asks its content for a minimum / ideal size on every layout pass
        // (NSHostingView.minSize, the window's content-size limits). A ScrollView answers by measuring its whole
        // content's ideal size — every reply, every block's text at its unwrapped width — so each reveal tick re-measured
        // the transcript (AT-008 probe profile: 36 % of the main thread under NSHostingView.minSize). Fixed minimum and
        // ideal sizes answer that query here; the proposed size during layout is unchanged.
        //
        // fix/u5-renderer-3: that frame answered size queries but not alignment queries. A stack above the transcript
        // asks its child's alignment guide, the frame answers by placing its child — the ScrollView — and that
        // measures the whole transcript again at the query's own proposal (a cache miss: every reply's text laid
        // out at another width). The perf-build probe's profile: 34 % of the main thread under NSHostingView.minSize,
        // on every pass while a reply streams. `OpaqueFill` answers both itself (`TranscriptMeasureTests`).
        .modifier(OpaqueFill())
        // Opens at the bottom and stays there as content grows, but a short chat sits at the top (ChatGPT).
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: FollowGeometry.self) { geo in
            FollowGeometry(geo, threshold: Self.attachThreshold)
        } action: { old, new in
            // VQ-M10 round 65 (S-15): the side panel opening (or the sidebar collapsing for it) re-wraps every row at
            // the new width, and the taller content left an attached view "away" before the anchor caught up: the
            // reply ended under a Jump-to-bottom button nobody had asked for. A re-wrap is not the reader scrolling.
            if !detached, new.away, widthMark.isRecent, !FollowGeometry.readerScrolledUp(old, new) {
                position.scrollTo(edge: .bottom)
                return
            }
            if FollowGeometry.readerScrolledUp(old, new) { readerMark.changedAt = ContinuousClock.now }
            // Q-015 r6 (QueueTests.testFollowUpQueued): the bottom margin grew under an attached view
            // while the offset stayed put — a queued follow-up bubble raising the margin
            // (`ConversationView.contentMargins`). That is not the reader scrolling away: keep following. Before, the
            // margin growth read as "away", the view detached, and the reply kept growing below the fold, under
            // the queued bubbles and the composer (whose hit point the clipped reply text then took).
            // RC e8fe19986 (VideoEntryTests.testAnimateOnImageCard, ModelInfoTests after a Stop): the same for the
            // content. A pending reply's late-sized part (a video plan card, an image card) or a streaming reply grows
            // the content under a still offset; `.defaultScrollAnchor(.bottom, for: .sizeChanges)` did not always
            // follow (a chat that had fitted the view, a jump in one pass), the growth read as "away" and the view
            // detached for good. Growth is followed unless the reader scrolled up just now (lazy rows measured above
            // the viewport while the reader scrolls up also grow the content: r6 p6 must not be pulled back down).
            if !detached, new.away, !readerMark.isRecent,
               FollowGeometry.grewUnderStillOffset(old, new) || FollowGeometry.contentGrewUnderStillOffset(old, new) {
                position.scrollTo(edge: .bottom)
                return
            }
            // Only a change of "away" moves `detached` (as before r6): Jump to bottom sets it false and scrolls; the
            // offsets of that scroll, still away until it lands, must not set it back.
            if old.away != new.away {
                if detached != new.away { detached = new.away }
            } else if new.away, !detached, FollowGeometry.readerScrolledUp(old, new) {
                // Already "away" while attached (a reply that grew under the view before the anchor caught up) and the
                // reader scrolls further up: that is the reader's own scroll, so Jump to bottom shows (r6 p7).
                detached = true
            }
        }
        .onChange(of: items.last) { _, _ in
            if !detached { position.scrollTo(edge: .bottom) }
        }
        // Q-015 r4: a new turn (the user's send adds its message and the pending reply) always brings the bottom into
        // view and re-attaches, as in ChatGPT. Before, a column left away from the bottom (a tall picture card growing
        // under a still view) stayed there, and the new turn was drawn below the fold, outside the lazy stack.
        .onChange(of: items.count) { old, new in
            guard new > old else { return }
            position.scrollTo(edge: .bottom)
            detached = false
        }
        .onChange(of: scrollTarget) { _, id in
            if let id { position.scrollTo(id: id, anchor: .center) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { _ in
            widthMark.changedAt = ContinuousClock.now
            if !detached { position.scrollTo(edge: .bottom) }
        }
        // On the scroll view itself, before the overlay: applied after it, "transcript" replaced JumpToBottom's own
        // identifier (Q-015 XCUITest catch-up).
        .probeID("transcript")
        .overlay(alignment: .bottom) {
            // fix/t05-u5-part5 (NFR-U5): the fade is the button's own. On the scroll view, a change of `detached` animated
            // the whole transaction it landed in: a reply growing under the view flips it (away for a pass, until the
            // anchor catches up), and every row's text display list was interpolated in that pass (perf-build profile:
            // `InterpolatedDisplayList` / `ResolvedStyledText.modifyTransition` in the reply's end pass).
            ZStack {
                if detached {
                    JumpToBottom {
                        position.scrollTo(edge: .bottom)
                        detached = false
                    }
                    .padding(.bottom, Spacing.space4)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: MotionToken.fast.duration), value: detached)
        }
    }
}

/// VQ-M10 round 65: when the transcript column last changed width. A plain reference (never observed), so the
/// geometry callback that sets it costs no transaction (the fix/selection-hang-2 rule).
final class WidthChangeMark {
    var changedAt: ContinuousClock.Instant?
    /// Within the re-wrap's settle time (rows re-measure over a few passes after the width changes).
    var isRecent: Bool { changedAt.map { ContinuousClock.now - $0 < .milliseconds(800) } ?? false }
}

/// What TranscriptList's follow rule reads from the scroll geometry: whether the view is away from the bottom, and
/// what can change under a still view (content height, bottom margin) versus the reader's scroll (offset).
struct FollowGeometry: Equatable {
    var away: Bool
    var contentHeight: CGFloat
    var bottomInset: CGFloat
    var offsetY: CGFloat

    init(away: Bool, contentHeight: CGFloat, bottomInset: CGFloat, offsetY: CGFloat) {
        self.away = away
        self.contentHeight = contentHeight
        self.bottomInset = bottomInset
        self.offsetY = offsetY
    }

    init(_ geo: ScrollGeometry, threshold: CGFloat) {
        self.init(away: Self.away(contentHeight: geo.contentSize.height, offsetY: geo.contentOffset.y,
                                  containerHeight: geo.containerSize.height, topInset: geo.contentInsets.top,
                                  bottomInset: geo.contentInsets.bottom, threshold: threshold),
                  contentHeight: geo.contentSize.height.rounded(), bottomInset: geo.contentInsets.bottom.rounded(),
                  offsetY: geo.contentOffset.y.rounded())
    }

    /// RC e8fe19986: `containerSize` excludes the content insets, and the offset of the top of the content is
    /// −topInset (the transcript scrolls under the window's toolbar, 52 pt). The view's bottom edge in content
    /// coordinates is offset + container + top inset; without the top inset a view at its very bottom read 52 pt
    /// "away" (> the 24 pt threshold), so every growth or send left it detached (Jump to bottom over the reply).
    static func away(contentHeight: CGFloat, offsetY: CGFloat, containerHeight: CGFloat, topInset: CGFloat,
                     bottomInset: CGFloat, threshold: CGFloat) -> Bool {
        let visible = containerHeight + topInset
        let distance = contentHeight + bottomInset - (offsetY + containerHeight + topInset)
        return contentHeight + bottomInset > visible && distance > threshold
    }

    /// The content grew while the offset did not move up (growth under the view, not the reader's scroll).
    static func contentGrewUnderStillOffset(_ old: FollowGeometry, _ new: FollowGeometry) -> Bool {
        new.contentHeight > old.contentHeight && new.offsetY >= old.offsetY - 1
    }

    /// The offset moved up (towards the start): only the reader does that (growth, anchors and Jump to bottom never do).
    /// RC e8fe19986 (ModelInfoTests after a Stop): content that shrinks under a view at the bottom (the previous
    /// reply's action bar giving way to the new turn, a pending row settling) clamps the offset up by the same
    /// amount in a later pass, and the view is still at the bottom: that is not the reader. Counted as a scroll it
    /// detached the view at every send, and each reply then grew below the fold. An upward move that leaves the view
    /// at the bottom (within the threshold) is never the reader leaving it.
    static func readerScrolledUp(_ old: FollowGeometry, _ new: FollowGeometry) -> Bool {
        new.offsetY < old.offsetY - 1 && new.away
    }

    /// The bottom margin (queued follow-up bubbles) grew while the offset did not move (nothing the reader did).
    static func grewUnderStillOffset(_ old: FollowGeometry, _ new: FollowGeometry) -> Bool {
        abs(new.offsetY - old.offsetY) < 1
            && new.bottomInset > old.bottomInset
        // Content growth is not counted: a streaming reply is kept at the bottom by `.defaultScrollAnchor(.bottom, for:
        // .sizeChanges)`, and the lazy rows measured above the viewport while the reader scrolls up also grow the
        // content under a still offset — counting them yanked the reader back down (r6 p6, WindowLayout jump-to-bottom).
    }
}

/// M1.T07 default transcript row: user text in a right-aligned bubble, assistant text unboxed (UserBubble /
/// AssistantMessageView from M1.T06 replace it at the W2 merge).
struct PlainTranscriptRow: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    let item: TranscriptItem

    var body: some View {
        switch item.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: readingWidth * (1 - Layout.userBubbleMaxWidthFraction))
                Text(verbatim: item.text)
                    .typeStyle(.body)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.space4)
                    .padding(.vertical, Spacing.space2)
                    .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.surfaceSunken))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
            .probeID("message.user")
        case .assistant, .other:
            Text(verbatim: item.text)
                .typeStyle(.body)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .probeID("message.assistant")
        }
    }
}

/// Fills the proposed space and answers every size and alignment query itself, never by measuring its content
/// (fix/u5-renderer-3). Minimum and ideal size 0, maximum unbounded (as `.frame(minWidth: 0, idealWidth: 0,
/// maxWidth: .infinity, …)`), default alignment guides; the content is placed at the full bounds, so its own layout
/// (the scroll view's) is the only one that measures it.
struct OpaqueFill: ViewModifier {
    func body(content: Content) -> some View {
        OpaqueFillLayout { content }
    }
}

struct OpaqueFillLayout: SwiftUI.Layout {
    #if DEBUG
    /// Size queries answered (tests).
    nonisolated(unsafe) static var sizeQueries = 0
    #endif

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        #if DEBUG
        Self.sizeQueries += 1
        #endif
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for s in subviews { s.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size)) }
    }

    // Not the protocol's default, which merges the subviews' guides (and so measures them).
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
