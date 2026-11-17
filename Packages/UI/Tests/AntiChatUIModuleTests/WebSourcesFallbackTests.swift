// A web answer always names its pages: when no inline citation is accepted, small chips for the pages it drew on
// follow the answer; the Sources panel lists each page once and shows a site's name once.
import Foundation
import Testing
@testable import AntiChatStorage
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct WebSourcesFallbackTests {
    static func source(_ n: Int, _ site: String, _ title: String, url: String? = nil, snippet: String = "") -> MessageProvenance.WebSourceRecord {
        MessageProvenance.WebSourceRecord(n: n, url: url ?? "https://\(site)/\(n)", title: title, site: site, date: nil,
                                          faviconData: nil, snippet: snippet, fetched: true)
    }

    @Test func trailingChipsForThePagesUsed() {
        let sources = [Self.source(1, "alltrails.com", "Best trails in Lisbon"),
                       Self.source(2, "alltrails.com", "Best trails in Sintra"),
                       Self.source(3, "walksintra.com", "Walk Sintra", snippet: "The Sintra mountain trails and the rugged coastline"),
                       Self.source(4, "example.org", "Cooking pasta")]
        let text = "The Sintra mountain trails follow the rugged coastline."
        let used = CitationPill.used(text: text, sources: sources)
        #expect(used.map(\.n).contains(3) && Set(used.map(CitationPill.siteKey)).count == used.count, "one chip per site")
        let shown = CitationPill.withTrailingChips(text, sources: sources)
        #expect(shown.hasPrefix(text + "\n\n") && shown.contains("](antichat-cite://3)"))
        #expect(CitationPill.withTrailingChips(text, sources: []) == text)
    }

    @Test func panelListsEachPageOnceAndASiteNameOnce() {
        let twice = [Self.source(1, "Open Travel Guide; Open Travel Guide", "10 Best Hikes", url: "https://opentravelguide.com/hikes/"),
                     Self.source(2, "opentravelguide.com", "10 Best Hikes", url: "https://opentravelguide.com/hikes"),
                     Self.source(3, "alltrails.com", "Lisbon")]
        let content = SourcesContent(sources: twice, citedOrder: [])
        #expect(content.all.map(\.n) == [1, 3] && content.cited.isEmpty)
        #expect(CitationPill.domain("Open Travel Guide; Open Travel Guide") == "Open Travel Guide")
        #expect(CitationPill.domain("www.alltrails.com") == "alltrails.com")
    }

    @Test func aMediaReplySaysItOnce() {
        let twice = "Here is a short video of a campfire at night.\n\nHere is your short video of a campfire at night."
        #expect(AssistantMessageView.withoutRepeatedSentence(twice) == "Here is your short video of a campfire at night.")
        let different = "Here is your picture.\n\nWant it in another style?"
        #expect(AssistantMessageView.withoutRepeatedSentence(different) == different)
    }
}
