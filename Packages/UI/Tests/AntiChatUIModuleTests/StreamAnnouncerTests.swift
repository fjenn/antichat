// M9.T01 AT-223 part 1 / AT-NFR-A2: VoiceOver hears a streamed reply politely — never per token. `.atEnd` posts one
// announcement at done; `.perSentence` posts each completed sentence at most once per 1.5 s; reasoning never.
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct StreamAnnouncerTests {
    /// Virtual clock: `sleep` advances time instantly, so the 1.5 s spacing is checked without waiting.
    final class Clock {
        var t = ContinuousClock.now
        var posts: [(StreamAnnouncer.Announcement, ContinuousClock.Instant)] = []
    }

    func make(_ mode: AnnounceReplies, _ c: Clock) -> StreamAnnouncer {
        StreamAnnouncer(mode: mode, now: { c.t }, sleep: { c.t = c.t.advanced(by: $0) }, post: { c.posts.append(($0, c.t)) })
    }

    /// A 12-sentence reply split into ~600 tiny token deltas (ScriptedEngine-style).
    static let sentences = (1...12).map { "Sentence number \($0) says something useful about the topic." }
    static func tokens() -> [String] {
        let text = sentences.joined(separator: " ")
        var out: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[i..<j])); i = j
        }
        return out
    }

    @Test func atEndPostsExactlyOnce() async {
        let c = Clock(); let a = make(.atEnd, c)
        a.begin()
        for t in Self.tokens() { a.replyDelta(t); a.reasoningDelta("thinking ") }
        #expect(c.posts.isEmpty)  // nothing while streaming
        a.finished()
        #expect(c.posts.count == 1)
        #expect(c.posts[0].0.priority == .standard)
        #expect(c.posts[0].0.text.count <= StreamAnnouncer.atEndLimit + 1)
        #expect(c.posts[0].0.text.hasPrefix("Sentence number 1 says"))
    }

    @Test func perSentenceTwelveAnnouncementsSpaced() async {
        let c = Clock(); let a = make(.perSentence, c)
        a.begin()
        let tokens = Self.tokens()
        #expect(tokens.count > 250)
        for t in tokens {
            a.replyDelta(t)
            a.reasoningDelta("reasoning that must never be spoken. ")
            #expect(c.posts.count <= 12)
        }
        a.finished()
        await a.drain()
        #expect(c.posts.count == 12)
        #expect(c.posts.allSatisfy { $0.0.priority == .low })
        #expect(c.posts.map(\.0.text) == Self.sentences)
        #expect(!c.posts.contains { $0.0.text.contains("reasoning") })
        for (p, q) in zip(c.posts, c.posts.dropFirst()) {
            #expect(q.1 - p.1 >= .milliseconds(1500))
        }
    }

    @Test func interruptAnnouncesOnceAndDropsTheQueue() async {
        let c = Clock(); let a = make(.perSentence, c)
        a.begin()
        a.replyDelta("First sentence here. Second one too. Third")
        a.interrupted()
        await a.drain()
        #expect(c.posts.last?.0.text == "Response interrupted.")
        #expect(c.posts.count <= 2)
    }

    @Test func activityAnnouncedOnce() async {
        let c = Clock(); let a = make(.atEnd, c)
        a.activity(id: "call-1", summary: "Searched the web · 4 sources")
        a.activity(id: "call-1", summary: "Searched the web · 4 sources")
        await a.drain()
        #expect(c.posts.map(\.0.text) == ["Searched the web · 4 sources"])
    }

    @Test func markdownIsSpokenAsText() {
        #expect(StreamAnnouncer.speakable("## Title\n- **bold** and `code` [link](https://x.y)") == "Title bold and code link")
    }

    @Test func evilWindowTitle() {
        #expect(WindowAccessibilityTitle.text(chatTitle: "Plans", evil: true, incognito: false) == "Plans, Evil mode chat")
        #expect(WindowAccessibilityTitle.text(chatTitle: "", evil: false, incognito: true) == "New chat, Incognito chat")
        #expect(WindowAccessibilityTitle.text(chatTitle: "Plans", evil: false, incognito: false) == "Plans")
    }
}
