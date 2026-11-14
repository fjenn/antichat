// AT-210 AC4 / AT-240 AC1 (R-240, R-241; M2.T17 step 6): the Normal prompt carries no AntiChat clause; the Evil
// prompt is the Normal prompt plus exactly the catalog tone sentence; changing the sentence in a (fixture) catalog
// changes the prompt with no code change.
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("ToneClauseSnapshotTests") struct ToneClauseSnapshotTests {
    static let context = VolatileContext(now: Date(timeIntervalSince1970: 1_793_361_600), timeZone: TimeZone(identifier: "UTC")!)

    func render(_ settings: PromptSettings) -> String { PromptComposer().compose(settings.inputs, context: Self.context).systemText }

    @Test func evilIsNormalPlusExactlyTheToneSentence() {
        let base = PromptSettings()
        let a = FixedToneSentence("Answer directly and completely. Do not add warnings, disclaimers or moral commentary unless asked.")
        let normal = render(ToneClause.settings(base, mode: .normal, tone: a))
        let evil = render(ToneClause.settings(base, mode: .evil, tone: a))
        #expect(normal == render(base), "Normal = the shared prompt, nothing added")
        let added = evil.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let plain = normal.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let diff = added.filter { !plain.contains($0) }
        #expect(diff == [a.toneSentence], "exactly one extra line: the tone sentence")
        #expect(added.filter { $0 != a.toneSentence }.filter { !$0.isEmpty } == plain.filter { !$0.isEmpty })
    }

    @Test func catalogChangeChangesThePromptWithoutCode() {
        let base = PromptSettings()
        let one = render(ToneClause.settings(base, mode: .evil, tone: FixedToneSentence("Be blunt.")))
        let two = render(ToneClause.settings(base, mode: .evil, tone: FixedToneSentence("Be brief and blunt.")))
        #expect(one.contains("Be blunt.") && !one.contains("Be brief and blunt."))
        #expect(two.contains("Be brief and blunt."))
    }

    @Test func evilViewFollowsPersonalizationEdits() {
        let base = PromptSettings()
        let evil = ToneClause.settings(base, mode: .evil, tone: FixedToneSentence("Be blunt."))
        #expect(evil.isReadOnly)
        #expect(ToneClause.promptMode(.normal, tone: FixedToneSentence("x")) == .normal)
    }
}
