// M9.T05 (AT-254 T3, A-M9-T05b follow-up): rule-written sub-queries for multi-part questions on the harness-written
// search. Cases: the 10 hand-written multi-part questions of the T3 A/B (build/at/AT-248/t05-multipart/) and the
// single-part AT-254 availability queries, which must not split.
@testable import AntiChatTools
import Testing

struct SearchQuerySplitTests {
    @Test func twoNamesSplitIntoOneQueryEach() {
        #expect(SearchQuerySplit.subQueries("Compare the populations of Lyon and Marseille.", max: 2)
                == ["Compare the populations of Lyon.", "Compare the populations of Marseille."])
        #expect(SearchQuerySplit.subQueries("What are the current policy interest rates of the ECB and the US Federal Reserve?", max: 2)
                == ["What are the current policy interest rates of the ECB?",
                    "What are the current policy interest rates of the US Federal Reserve?"])
        #expect(SearchQuerySplit.subQueries("What are the latest macOS and iOS versions, and when were they released?", max: 2)
                == ["What are the latest macOS versions, and when were they released?",
                    "What are the latest iOS versions, and when were they released?"])
        #expect(SearchQuerySplit.subQueries("How do the battery capacities of the iPhone 17 and the Pixel 10 compare?", max: 2)
                == ["How do the battery capacities of the iPhone 17 compare?", "How do the battery capacities of the Pixel 10 compare?"])
        #expect(SearchQuerySplit.subQueries("What are the latest stable versions of Rust and Go?", max: 2)
                == ["What are the latest stable versions of Rust?", "What are the latest stable versions of Go?"])
    }

    @Test func clausesSplitAndABackReferenceGetsTheTopic() {
        #expect(SearchQuerySplit.subQueries("Who won the 2025 Nobel Prize in Physics and what was it awarded for?", max: 2)
                == ["Who won the 2025 Nobel Prize in Physics", "what was it awarded for won 2025 Nobel Prize Physics"])
        #expect(SearchQuerySplit.subQueries("What's new in Python 3.14, and when does Python 3.9 reach end of life?", max: 2)
                == ["What's new in Python 3.14", "when does Python 3.9 reach end of life"])
        #expect(SearchQuerySplit.subQueries("Who is the CEO of Nvidia and what was its most recent quarterly revenue?", max: 2)
                == ["Who is the CEO of Nvidia", "what was its most recent quarterly revenue CEO Nvidia"])
        #expect(SearchQuerySplit.subQueries("When is the next total solar eclipse visible from Europe, and which countries will see it?", max: 2)
                == ["When is the next total solar eclipse visible from Europe",
                    "which countries will see it next total solar eclipse visible Europe"])
    }

    @Test func singlePartQuestionsDoNotSplit() {
        for q in ["latest wildfire news", "what happened with rail strike recently", "What's the latest macOS version?",
                  "olympic games update today", "Who wrote War and Peace?", "rock and roll history"] {
            #expect(SearchQuerySplit.subQueries(q, max: 2).isEmpty, "\(q)")
        }
        #expect(SearchQuerySplit.subQueries("Compare the populations of Lyon and Marseille.", max: 0).isEmpty)
        #expect(SearchQuerySplit.subQueries("Compare the populations of Lyon and Marseille.", max: 1).count == 1)
    }
}
