// AT-001 leg (3)/(4) unit half (M1.T07): one headline (empty.headline) on every new chat;
// suggestion cards are ≤ 4, only from enabled packs' static lists, deterministic per seed, and never need a network.
import AntiChatDesign
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatUI

@Suite(.isolatedSettings) struct SuggestionProviderTests {
    @Test func oneHeadlineForEveryNewChat() {
        #expect(EmptyHeadline.key.isKnown && EmptyHeadline.key.rawValue == "empty.headline")
        #expect(Set((UInt64(1)...30).map { EmptyHeadline.pick(seed: $0) }) == [EmptyHeadline.key])
    }

    @Test func chatOnlyGivesTheFourChatLines() {
        for seed in UInt64(0)..<50 {
            let s = SuggestionProvider.suggestions(enabled: [.chat], seed: seed)
            #expect(s.count == 4)
            #expect(Set(s.map(\.key.rawValue)) == ["sugg.chat.1", "sugg.chat.2", "sugg.chat.3", "sugg.chat.4"])
        }
    }

    @Test func neverMoreThanFourAndOnlyEnabledPacks() {
        let packSets: [Set<SuggestionPack>] = [[], [.chat], [.chat, .voice], [.chat, .photo, .files],
                                                Set(SuggestionPack.allCases), [.voice, .photo]]
        for enabled in packSets {
            for seed in UInt64(0)..<40 {
                let s = SuggestionProvider.suggestions(enabled: enabled, seed: seed)
                #expect(s.count <= SuggestionProvider.maxCards)
                #expect(s.allSatisfy { enabled.contains($0.pack) })
                #expect(Set(s.map(\.id)).count == s.count, "duplicate card")
                #expect(s == SuggestionProvider.suggestions(enabled: enabled, seed: seed))
            }
        }
    }

    @Test func installedPacksShowOneLineEach() {
        let s = SuggestionProvider.suggestions(enabled: [.chat, .voice, .photo], seed: 9)
        #expect(s.contains { $0.pack == .voice })
        #expect(s.contains { $0.pack == .photo })
        #expect(s.count == 4)
    }

    @Test func everySuggestionKeyIsInTheDeck() {
        for s in SuggestionProvider.catalog.values.flatMap({ $0 }) {
            #expect(s.key.isKnown, "missing copy key \(s.key)")
            #expect(!s.text.isEmpty && s.text != s.key.rawValue)
        }
    }

    @Test func enabledPacksFollowTheLaunchOptions() {
        #expect(SuggestionProvider.enabledPacks(options: LaunchOptions()) == [.chat])
        var o = LaunchOptions()
        o.fakeInstalledPacks = ["voice", "photo", "bogus"]
        o.fakeDisabledPacks = ["photo"]
        #expect(SuggestionProvider.enabledPacks(options: o) == [.chat, .voice])
    }

    /// Leg (4) "no network": the provider is static data. Its source file must not reference any networking API.
    @Test func providerSourceHasNoNetworkPath() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/AntiChatUI/Empty/SuggestionProvider.swift").standardized
        let src = try String(contentsOf: file, encoding: .utf8)
        for banned in ["URLSession", "URLRequest", "NetworkGate", "http://", "https://", "EngineClient"] {
            #expect(!src.contains(banned), "SuggestionProvider references \(banned)")
        }
    }
}
