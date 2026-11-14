// M8.T05 (R-245 AC2; AT-245 visual bar "zero pills without a resolved source"): `[n]` / `[source n]` of a project
// reply become file pills only for the reply's numbered passages; others are removed; Markdown links stay.
//   make test-unit FILTER=ProjectCitePillTests
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct ProjectCitePillTests {
    let sources: [MessageProvenance.ProjectSource] = [
        .init(n: 1, fileID: "f1", name: "report.pdf", page: "7"),
        .init(n: 2, fileID: "f2", name: "assets.xlsx", page: "Assets"),
    ]

    @Test func resolvedCitationsBecomeLinksOthersAreDropped() {
        let out = ProjectCitePill.linkify("The permit is HAF-4471 [1]. Custodian Rosa Thorne [source 2], see [9].", sources: sources)
        #expect(out.contains("(antichat-project://f1/7)") && out.contains("report.pdf, p. 7"))
        #expect(out.contains("(antichat-project://f2/0)") && out.contains("assets.xlsx, Assets"))
        #expect(!out.contains("[9]") && out.hasSuffix("see."))
        #expect(ProjectCitePill.linkify("x [1, 2]", sources: sources).components(separatedBy: "antichat-project://").count == 3)
        #expect(ProjectCitePill.linkify("[a link](https://x.y) [1](z)", sources: sources) == "[a link](https://x.y) [1](z)")
        #expect(ProjectCitePill.linkify("no sources [1]", sources: []) == "no sources [1]")
        let t = ProjectCitePill.target(URL(string: "antichat-project://f1/7")!)
        #expect(t?.fileID == "f1" && t?.page == 7)
    }
}
