// M6.T01 step 6: EPUB → one `## <chapter title>` section per spine item, in spine order.
//   make test-unit FILTER=EPUBAdapterTests
import Foundation
import Testing
@testable import AntiChatKnowledge

@Suite struct EPUBAdapterTests {
    @Test func chaptersInSpineOrder() throws {
        let doc = try EPUBAdapter().extract(url: IntakeFixtures.url("docs/epub/sample.epub"))
        #expect(doc.units.count == 3)
        #expect(doc.units.allSatisfy { $0.kind == .section })
        #expect(doc.units.map(\.index) == [1, 2, 3])
        for (i, u) in doc.units.enumerated() {
            let text = doc.text(of: u)
            #expect(text.hasPrefix("## Chapter \(i + 1):"), "\(text.prefix(40))")
            #expect(u.label?.hasPrefix("Chapter \(i + 1):") == true)
            #expect(text.split(separator: "\n").count >= 4, "heading + 3 paragraphs")
            #expect(!text.contains("<"))
        }
    }

    @Test func pathsResolveAgainstTheOPF() {
        #expect(EPUBAdapter.resolve("text/ch1.xhtml", base: "OEBPS") == "OEBPS/text/ch1.xhtml")
        #expect(EPUBAdapter.resolve("../ch%201.xhtml#x", base: "OEBPS/a") == "OEBPS/ch 1.xhtml")
        #expect(EPUBAdapter.resolve("ch.xhtml", base: "") == "ch.xhtml")
    }

    @Test func notAnEPUB() {
        #expect(throws: EPUBAdapterError.notAnEPUB) {
            try EPUBAdapter().extract(url: IntakeFixtures.url("docs/text/sample.txt"))
        }
    }
}
