// ⌘F find in chat and the transcript-only ⌘A (M1.T24 steps 2–3; R-103).
// - `FindInChatModel`: the bar's query and its matches over the visible path's message texts (case- and
//   diacritic-insensitive, every occurrence counted), the current match, next/previous with wrap-around. The bar
//   floats over the transcript's top edge; rows with a match are tinted and the current one is outlined and
//   scrolled to (row-level highlight: the replies are rendered Markdown, A-M1-T24a).
// - `TranscriptSelection`: Edit › Select All while no text field has focus selects the conversation only (every
//   message on the visible path, tinted as selected) and Copy copies exactly that text; with the composer (or any
//   text field) focused both keep their usual meaning (EditCommands).
import AntiChatDesign
import SwiftUI

@MainActor
@Observable
public final class FindInChatModel {
    public struct Match: Equatable, Sendable {
        public let messageID: String
        /// Character offsets of the occurrence in the message text.
        public let range: Range<Int>
    }

    public private(set) var isPresented = false
    public var query = "" {
        didSet { if query != oldValue { search(keepCurrent: false) } }
    }
    public private(set) var matches: [Match] = []
    public private(set) var current: Int?
    /// Bumped by `present()`: the bar's field takes focus (again) on each ⌘F.
    public private(set) var focusRequest = 0

    private var texts: [(id: String, text: String)] = []
    /// The transcript's texts, read when the bar opens and on each query change (set by ConversationModel).
    @ObservationIgnored var source: (@MainActor () -> [(id: String, text: String)])?

    public init() {}

    public func present() {
        if !isPresented, let source { texts = source() }
        isPresented = true
        focusRequest += 1
    }

    public func dismiss() {
        isPresented = false
        query = ""
        matches = []
        current = nil
    }

    /// The transcript changed (a reply streamed, a version switched): recount, keeping the current match's place.
    public func update(_ messages: [(id: String, text: String)]) {
        texts = messages
        search(keepCurrent: true)
    }

    public func next() { step(1) }
    public func previous() { step(-1) }

    public var currentMatch: Match? { current.map { matches[$0] } }
    public var matchedIDs: Set<String> { Set(matches.map(\.messageID)) }

    /// "3 of 7", "No results", or nothing while the field is empty.
    public var label: String {
        guard !query.isEmpty else { return "" }
        guard let current else { return CopyKey("find.none").string() }
        return CopyKey("find.count").string(["current": "\(current + 1)", "total": "\(matches.count)"])
    }

    private func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        let n = matches.count
        current = ((current ?? (by > 0 ? -1 : 0)) + by + n) % n
    }

    private func search(keepCurrent: Bool) {
        if !keepCurrent, let source { texts = source() }
        let before = keepCurrent ? currentMatch : nil
        matches = Self.matches(of: query, in: texts)
        if matches.isEmpty {
            current = nil
        } else if let before, let i = matches.firstIndex(of: before) ?? matches.firstIndex(where: { $0.messageID == before.messageID }) {
            current = i
        } else {
            current = 0
        }
    }

    /// Every occurrence of `query` in `texts`, in transcript order.
    nonisolated static func matches(of query: String, in texts: [(id: String, text: String)]) -> [Match] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var out: [Match] = []
        for (id, text) in texts {
            var from = text.startIndex
            while from < text.endIndex,
                  let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                out.append(Match(messageID: id, range: lo..<(lo + text.distance(from: r.lowerBound, to: r.upperBound))))
                from = r.upperBound
            }
        }
        return out
    }
}

/// The transcript-only selection of ⌘A.
@MainActor
@Observable
public final class TranscriptSelection {
    public private(set) var isAll = false
    public init() {}

    public func selectAll() { isAll = true }
    public func clear() { if isAll { isAll = false } }

    /// The conversation's text as ⌘C copies it: each message on the visible path, in order, blank-line separated.
    public static func text(of messages: [(role: String, text: String)]) -> String {
        messages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// The find bar (floats over the transcript's top edge).
struct FindBar: View {
    @Bindable var model: FindInChatModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textSecondary)
            TextField(text: $model.query) { Text(CopyKey("find.placeholder")) }
                .textFieldStyle(.plain)
                .typeStyle(.callout)
                .focused($focused)
                .frame(minWidth: 180)
                .onSubmit { model.next() }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.previous()
                    return .handled
                }
                .onExitCommand { model.dismiss() }
                .probeID("findField")
            Text(verbatim: model.label)
                .typeStyle(.footnote)
                .foregroundStyle(Color.textSecondary)
                .monospacedDigit()
                .probeID("findCount")
            Button { model.previous() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(model.matches.isEmpty)
                .help(Text(CopyKey("find.previous")))
                .accessibilityLabel(Text(CopyKey("find.previous")))
                .probeID("findPrevious")
            Button { model.next() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(model.matches.isEmpty)
                .help(Text(CopyKey("find.next")))
                .accessibilityLabel(Text(CopyKey("find.next")))
                .probeID("findNext")
            Button { model.dismiss() } label: { Text(CopyKey("find.done")) }
                .buttonStyle(.borderless)
                .probeID("findDone")
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.surfaceRaised))
        // Drawing only: an overlaid shape takes the clicks meant for the field under it (fix/overlay-field-focus).
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        .padding(.top, Spacing.space3)
        .onAppear { focused = true }
        .onChange(of: model.focusRequest) { _, _ in focused = true }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("findBar")
    }
}

/// Row decoration for find matches and the ⌘A selection.
struct TranscriptRowHighlight: ViewModifier {
    let matched: Bool
    let current: Bool
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if selected || matched {
                    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .fill(selected ? Color(nsColor: .selectedTextBackgroundColor) : Color.accent.opacity(0.10))
                        .padding(-Spacing.space2)
                        .probeID(selected ? "transcriptSelected" : "findMatch")
                }
            }
            .overlay {
                if current {
                    RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                        .strokeBorder(Color.accent, lineWidth: 2)
                        .padding(-Spacing.space2)
                        .probeID("findCurrent")
                }
            }
    }
}
