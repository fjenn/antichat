// M6 review #12: a "(p. N)" pill links only when exactly one attached PDF has page N; a page several files share stays
// plain text, and a deck (whose `pages` is its slide count) is never a page target.
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct PageCitePillReviewTests {
    static func whole(_ id: String, pages: Int, pdf: Bool) -> MessageProvenance.FileUse {
        .init(attachmentID: id, mode: ExcerptPolicy.whole.rawValue, pages: [], name: id, pageCount: pages, pdf: pdf)
    }

    @Test func pageOfTwoPDFsIsNotLinkedToTheFirst() {
        let uses = [Self.whole("a", pages: 10, pdf: true), Self.whole("b", pages: 8, pdf: true)]
        #expect(PageCitePill.owner(of: 5, in: uses) == nil, "page 5 is in both files")
        #expect(PageCitePill.owner(of: 9, in: uses) == "a")
        let text = PageCitePill.linkify("Total 12 (p. 5). Later (p. 9).", uses: uses)
        #expect(text.contains("(p. 5)") && !text.contains("antichat-page://a/5"), "\(text)")
        #expect(text.contains("antichat-page://a/9"), "\(text)")
    }

    @Test func deckSlidesAreNotPages() {
        let uses = [Self.whole("deck", pages: 4, pdf: false)]
        #expect(PageCitePill.owner(of: 2, in: uses) == nil)
        #expect(!PageCitePill.linkify("See (p. 2).", uses: uses).contains("antichat-page"))
        // Rows from before the flag still link (a lone whole PDF).
        let legacy = [MessageProvenance.FileUse(attachmentID: "old", mode: "whole", pages: [], pageCount: 3)]
        #expect(PageCitePill.owner(of: 2, in: legacy) == "old")
    }
}
