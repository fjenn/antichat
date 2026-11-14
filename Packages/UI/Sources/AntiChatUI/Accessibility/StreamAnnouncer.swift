// M9.T01 step 3 (R-223 AC1, NFR-A2): VoiceOver hears a streamed reply politely, never per token.
// `.atEnd`: one announcement (the first 400 characters) when the reply is done, "Response interrupted." on an
// interrupt. `.perSentence`: deltas are buffered, cut into sentences with NLTokenizer, and each completed sentence
// is queued at `.low` priority, at most one announcement per `minInterval` (1.5 s). Reasoning is never announced;
// a tool/memory activity line announces its one-line summary once. One announcer per conversation; the
// conversation feeds it only for its own (focused) reply.
import AntiChatDesign
import AntiChatFoundation
import AppKit
import NaturalLanguage

@MainActor
public final class StreamAnnouncer {
    public enum Priority: Sendable, Equatable { case low, standard }
    public struct Announcement: Sendable, Equatable {
        public var text: String
        public var priority: Priority
    }

    public static let atEndLimit = 400

    public var mode: AnnounceReplies
    let minInterval: Duration
    let post: @MainActor (Announcement) -> Void
    let now: () -> ContinuousClock.Instant
    let sleep: (Duration) async -> Void

    private var text = ""            // the reply so far (atEnd)
    private var buffer = ""          // not yet segmented (perSentence)
    private var queue: [String] = []
    private var lastPost: ContinuousClock.Instant?
    private var draining: Task<Void, Never>?
    private var announcedActivities: Set<String> = []

    public init(mode: AnnounceReplies, minInterval: Duration = .milliseconds(1500),
                now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                post: @escaping @MainActor (Announcement) -> Void = { StreamAnnouncer.systemPost($0) }) {
        self.mode = mode
        self.minInterval = minInterval
        self.now = now
        self.sleep = sleep
        self.post = post
    }

    /// A new reply starts: drop what is left of the previous one.
    public func begin() {
        text = ""; buffer = ""; queue = []
        draining?.cancel(); draining = nil
    }

    public func replyDelta(_ s: String) {
        text += s
        guard mode == .perSentence else { return }
        buffer += s
        let (done, rest) = Self.completedSentences(in: buffer)
        buffer = rest
        enqueue(done)
    }

    /// Reasoning text: never announced.
    public func reasoningDelta(_: String) {}

    public func activity(id: String, summary: String) {
        guard !summary.isEmpty, announcedActivities.insert(id).inserted else { return }
        enqueue([summary])
    }

    public func finished() {
        switch mode {
        case .atEnd:
            let clean = Self.speakable(text)
            guard !clean.isEmpty else { return }
            let cut = clean.count > Self.atEndLimit ? String(clean.prefix(Self.atEndLimit)) + "…" : clean
            emit(Announcement(text: cut, priority: .standard))
        case .perSentence:
            let tail = Self.speakable(buffer)
            buffer = ""
            if !tail.isEmpty { enqueue([tail]) }
        }
        text = ""
    }

    public func interrupted() {
        buffer = ""; text = ""; queue = []
        draining?.cancel(); draining = nil
        emit(Announcement(text: CopyKey("a11y.interrupted").string(), priority: .standard))
    }

    /// Waits until every queued sentence is out (tests).
    public func drain() async { await draining?.value }

    private func enqueue(_ items: [String]) {
        let items = items.map(Self.speakable).filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        queue += items
        guard draining == nil else { return }
        draining = Task { [weak self] in
            while let self, !self.queue.isEmpty, !Task.isCancelled {
                if let last = self.lastPost {
                    let wait = self.minInterval - (self.now() - last)
                    if wait > .zero { await self.sleep(wait) }
                }
                guard !Task.isCancelled, !self.queue.isEmpty else { break }
                self.emit(Announcement(text: self.queue.removeFirst(), priority: .low))
            }
            self?.draining = nil
        }
    }

    private func emit(_ a: Announcement) {
        lastPost = now()
        post(a)
    }

    // MARK: - Text

    /// Sentences NLTokenizer sees as complete (followed by more text) and the unfinished rest.
    nonisolated static func completedSentences(in s: String) -> ([String], String) {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = s
        var ranges: [Range<String.Index>] = []
        tok.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in ranges.append(r); return true }
        guard let last = ranges.last else { return ([], s) }
        var done = ranges
        var rest = ""
        // The last sentence is complete only once it ends in sentence punctuation and more text (a space) follows.
        let lastText = s[last].trimmingCharacters(in: .whitespacesAndNewlines)
        let ends = lastText.last.map { ".!?…。".contains($0) } ?? false
        if !(ends && s.last?.isWhitespace == true) {
            done.removeLast()
            rest = String(s[last.lowerBound...])
        }
        return (done.map { String(s[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }, rest)
    }

    /// Markdown markers VoiceOver would read aloud, removed.
    nonisolated static func speakable(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "```", with: " ")
        for m in ["**", "__", "`", "~~"] { t = t.replacingOccurrences(of: m, with: "") }
        t = t.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|[-*+]|>)\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        return t.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - System

    /// NSAccessibility announcement on the key window (the AppKit path M9.md names as the reliable fallback for
    /// SwiftUI's AccessibilityNotification; queued by VoiceOver, so it never cuts the user's own reading).
    /// No application object (a process that never made one, e.g. a test run of a logic suite alone): nothing to
    /// announce to. `NSApp` is implicitly unwrapped, and reading `.keyWindow` through nil trapped.
    public static func systemPost(_ a: Announcement) {
        guard let app = NSApp as NSApplication? else { return }
        let element: Any = app.keyWindow ?? app.mainWindow ?? app
        let level: NSAccessibilityPriorityLevel = a.priority == .low ? .low : .medium
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: a.text, .priority: level.rawValue])
    }
}
