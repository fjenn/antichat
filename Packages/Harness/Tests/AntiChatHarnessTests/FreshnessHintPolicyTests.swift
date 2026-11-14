// M7.T05 (R-228 AC1–AC4): when the fresh-information hint shows, its offline variant, the date rule against the
// model's knowledge cutoff, stable guards, the router leg, and that deciding never turns web search on.
//   make test-unit FILTER='FreshnessHintPolicyTests|NoAutoEnableTests'
import AntiChatFoundation
import AntiChatNetwork
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

struct FreshnessHintPolicyTests {
    let d = try! #require(FreshnessDetector.bundled)

    func hint(_ p: String, _ s: WebSearchAvailability.State = .switchedOff, dismissed: Bool = false, suggest: Bool = true,
              cutoff: String? = "2026-01", score: Float? = nil) -> FreshnessHintPolicy.Hint? {
        FreshnessHintPolicy.hint(prompt: p, detector: d, cutoff: cutoff, webNeededScore: score, search: s, dismissed: dismissed,
                                 suggestEnabled: suggest)
    }

    @Test func showsForFreshQuestionsWhileSearchIsOff() {
        #expect(hint("What's the weather in Lisbon today?") == .offer)
        #expect(hint("Wie wird das Wetter morgen in Hamburg?") == .offer)
        #expect(hint("¿Cuál es el precio actual del Bitcoin?") == .offer)
        #expect(hint("Why is the sky blue?") == nil)
    }

    @Test func neverWhenSearchIsOnDismissedOrSettingOff() {
        #expect(hint("What's the weather in Lisbon today?", .available) == nil)
        #expect(hint("What's the weather in Lisbon today?", dismissed: true) == nil)
        #expect(hint("What's the weather in Lisbon today?", suggest: false) == nil)
    }

    @Test func offlineVariantHasNoButtons() {
        #expect(hint("Any news on interest rates?", .offlineOnly) == .offline)
        #expect(hint("Any news on interest rates?", .noNetwork) == .offline)
    }

    @Test func dateRuleUsesTheCutoff() {
        #expect(d.hit("Who won the Ballon d'Or in 2026?", cutoff: "2025-06") == .date)
        #expect(d.hit("What happened in 2018?", cutoff: "2025-06") == nil)
        #expect(d.hit("Summarise the year 2025", cutoff: "2025-12") == nil)
        #expect(d.cutoff(forModel: "chat-9b-q4") == "2026-01" && d.cutoff(forModel: "unknown-model") == "2025-12")
    }

    @Test func stableGuardsAndRouterLeg() {
        #expect(d.hit("Explain how a weather forecast model works", cutoff: nil) == nil)
        #expect(d.hit("What is the current in a circuit with a 10 ohm resistor at 5 volts?", cutoff: nil) == nil)
        #expect(d.hit("Who runs OpenAI now?", cutoff: nil, webNeededScore: 0.2) == .router)
        #expect(d.hit("Who runs OpenAI now?", cutoff: nil, webNeededScore: 0.01) == nil)
    }
}

struct NoAutoEnableTests {
    /// AT-228 c2: deciding the hint over many prompts never writes the search switch (only consent does).
    @Test func decidingNeverTurnsSearchOn() {
        let defaults = UserDefaults.inMemory()
        let policy = NetworkPolicyStore(defaults: defaults)
        policy.setEnabled(.search, false)
        let d = FreshnessDetector.bundled
        let prompts = (0..<200).map { i in i % 2 == 0 ? "What's the latest news \(i)?" : "Explain topic \(i)" }
        for p in prompts {
            _ = FreshnessHintPolicy.hint(prompt: p, detector: d, cutoff: "2026-01", search: .switchedOff, dismissed: false,
                                         suggestEnabled: true)
        }
        #expect(!policy.storedValue(.search) && defaults.object(forKey: NetworkPolicyStore.key(.search)) as? Bool == false)
    }
}
