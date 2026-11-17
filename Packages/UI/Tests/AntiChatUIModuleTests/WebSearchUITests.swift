// M7.T03 UI module tests (R-080 AC1/AC3/AC4, R-250 AC1): citation pills only for fetched sources (with the page
// pills of M6 untouched), the Sources panel content (every fetched page, cited first, then More), the consent flow
// (off → on asks; Not now leaves it off; the + row adds its chip only after consent), the offline chip, and the
// one-shot "Read this URL" chip. The XCUITest leg (App/UITests/WebSearchUITests.swift) is pending Q-015; the
// in-process probe (`-SearchProbe`) runs the window legs.
//   make test-unit FILTER=WebSearchUITests
import AntiChatDesign
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Defaults
import Foundation
import Testing
@testable import AntiChatHarness
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct WebSearchUITests {
    static func src(_ n: Int, fetched: Bool = true, site: String? = nil) -> MessageProvenance.WebSourceRecord {
        .init(n: n, url: "https://s\(n).test/p", title: "Title \(n)", site: site ?? "www.s\(n).test", date: nil, faviconData: nil,
              snippet: "snippet \(n)", fetched: fetched)
    }

    @Test func pillsOnlyForFetchedSources() {
        let sources = (1...9).map { Self.src($0, fetched: $0 <= 4) }
        let text = (1...9).map { "Fact \($0) [\($0)]." }.joined(separator: " ") + " Both [2,7]."
        let r = CitationPill.linkify(text, sources: sources)
        let pills = CitationPill.pattern(in: r.text)
        #expect(pills == ["1", "2", "3", "4", "2"], "only 1–4 are fetched; [2,7] keeps 2")
        #expect(r.dropped == 6)
        #expect(r.cited == [1, 2, 3, 4])
        #expect(r.text.contains("Fact 5.") && !r.text.contains("[5]"), "an invalid marker is removed, no stray space")
        #expect(r.text.contains("[s1.test](antichat-cite://1)"), "the pill shows the domain without www.")
    }

    @Test func pillsLeavePageCitationsAndPlainTextAlone() {
        let page = "See [p. 3](antichat-page://att/3) and the list [a] item."
        #expect(CitationPill.linkify(page, sources: [Self.src(1)]).text == page)
        #expect(CitationPill.linkify("No sources [1].", sources: []).text == "No sources [1].")
    }

    @Test func multiSourcePillLabelAndNumbers() {
        let r = CitationPill.linkify("X [1, 2].", sources: [Self.src(1), Self.src(2)])
        #expect(r.text.contains("[s1.test +1](antichat-cite://1,2)"))
        #expect(CitationPill.numbers(URL(string: "antichat-cite://1,2")!) == [1, 2])
        #expect(CitationPill.numbers(URL(string: "https://x.test")!).isEmpty)
    }

    @Test func sourcesPanelListsEveryFetchedPageCitedFirst() {
        let content = SourcesContent(sources: [Self.src(1), Self.src(2), Self.src(3, fetched: false), Self.src(4)], citedOrder: [4, 1, 3])
        #expect(content.cited.map(\.n) == [4, 1], "cited order, unfetched never listed")
        #expect(content.more.map(\.n) == [2])
        let panel = SidePanelModel(windowID: "test-\(UUID().uuidString)")
        panel.openSources(content)
        #expect(panel.isOpen && panel.sources == content && panel.current == nil && panel.title == "Sources")
        panel.open(file: URL(fileURLWithPath: "/tmp/a.pdf"))
        #expect(panel.sources == nil, "a file replaces the sources view")
    }

    @Test func consentOffToOnAsksAndNotNowLeavesItOff() {
        let d = UserDefaults.inMemory()
        let policy = NetworkPolicyStore(defaults: d)
        policy.setEnabled(.search, false)
        let consent = WebSearchConsent(policy: policy, registry: EngineRegistry())
        var answers: [Bool] = []
        consent.request(from: .settings) { answers.append($0) }
        #expect(consent.presented == .settings)
        #expect(consent.engines.contains("DuckDuckGo") && consent.engines.contains("Wikipedia") && !consent.engines.contains("Google"))
        consent.answer(false)
        #expect(answers == [false] && !policy.storedValue(.search) && consent.presented == nil)
        consent.request(from: .main) { answers.append($0) }
        consent.answer(true)
        #expect(answers == [false, true] && policy.storedValue(.search))
        consent.request(from: .main) { answers.append($0) }
        #expect(consent.presented == nil && answers.last == true, "already on: no sheet")
        #expect(CopyText(CopyKey("search.consent.body"), ["engines": consent.engines]).string.contains("Never your chats or your name."))
    }

    @Test func webRowNeedsConsentThenAddsItsChip() {
        let menus = ComposerMenus()
        var c = ComposerMenuContext(activeModelKey: "chat-9b-q4")
        c.webSearch = .switchedOff
        menus.context = c
        var pending: ((Bool) -> Void)?
        menus.requestWebConsent = { done in pending = done }
        let web = try! #require(menus.addItems.first { $0.id == "web" })
        menus.pickAdd(web)
        #expect(menus.chips.ids.isEmpty && pending != nil, "consent first, no chip yet")
        pending?(false)
        #expect(menus.chips.ids.isEmpty)
        menus.pickAdd(web)
        c.webSearch = .available
        menus.context = c
        pending?(true)
        #expect(menus.chips.chips.map(\.id) == ["web"])
    }

    @Test func offlineChipStaysShownAsOffline() {
        let menus = ComposerMenus()
        var c = ComposerMenuContext(activeModelKey: "chat-9b-q4")
        c.webSearch = .available
        menus.context = c
        menus.pickAdd(menus.addItems.first { $0.id == "web" }!)
        c.webSearch = .noNetwork
        menus.context = c
        #expect(menus.chips.chips.map(\.id) == ["web"] && menus.chips.chips.first?.item.state == .offline)
        #expect(ComposerMenus.reason(.offline)?.string == "Needs the internet")
    }

    /// R-080 AC4 (Q-015 r5, AT-080 UI leg testOfflineChipAndNotice): picking Web search while offline adds the chip,
    /// shown as offline (the + row is pickable; the chip model refused it before).
    @Test func pickingWebSearchOfflineAddsAnOfflineChip() {
        let menus = ComposerMenus()
        var c = ComposerMenuContext(activeModelKey: "chat-9b-q4")
        c.webSearch = .offlineOnly
        menus.context = c
        let web = menus.addItems.first { $0.id == "web" }!
        #expect(web.state == .offline)
        menus.pickAdd(web)
        #expect(menus.chips.chips.map(\.id) == ["web"] && menus.chips.chips.first?.item.state == .offline)
    }

    @Test func readThisURLIsOneShotAndNotStored() {
        let chips = ToolChipsModel()
        chips.noticeURL(in: "summarise https://example.com/a?b=1 please", searchAvailable: true)
        #expect(chips.readURLSuggestion?.absoluteString == "https://example.com/a?b=1")
        chips.noticeURL(in: "example.com only", searchAvailable: true)
        #expect(chips.readURLSuggestion == nil, "a bare domain is not a pasted URL")
        chips.noticeURL(in: "https://example.com/a", searchAvailable: false)
        #expect(chips.readURLSuggestion == nil, "not offered while search is off or offline")
        chips.noticeURL(in: "https://example.com/a", searchAvailable: true)
        chips.acceptReadURL()
        #expect(chips.chips.map(\.id) == ["readUrl"] && chips.toolsJSON == nil, "forced, never sticky in tools_json")
        #expect(ComposerMenus.title(chips.chips[0].item) == "Read this URL")
        chips.clearReadURL()
        #expect(chips.chips.isEmpty)
    }

    /// R-091 AC3: the region hint is shown on the step when the requests carried one (and only then); the source of
    /// the hint is nil unless the setting is on and Location is granted.
    @Test func searchRegionHintOnActivityLineAndSource() {
        let rows = "\nrule\n\nSources:\n[1] A — a.test — https://a.test/\n\n</web_results>"
        let with = ToolActivity(id: "r1", tool: "web_search", state: .done, argumentsJSON: #"{"queries":["q"]}"#,
                                result: "<web_results untrusted=\"true\" date=\"2026-11-08\" region=\"de\">" + rows)
        #expect(SearchActivity.region(with) == "DE")
        #expect(SearchActivity.label(with)?.string == "Searched the web · 1 source · region hint DE")  // plural key: singular form
        let two = rows.replacingOccurrences(of: "\n\n</web_results>", with: "\n[2] B — b.test — https://b.test/\n\n</web_results>")
        let withTwo = ToolActivity(id: "r3", tool: "web_search", state: .done, argumentsJSON: #"{"queries":["q"]}"#,
                                   result: "<web_results untrusted=\"true\" date=\"2026-11-08\" region=\"de\">" + two)
        #expect(SearchActivity.label(withTwo)?.string == "Searched the web · 2 sources · region hint DE")
        let without = ToolActivity(id: "r2", tool: "web_search", state: .done, argumentsJSON: #"{"queries":["q"]}"#,
                                   result: "<web_results untrusted=\"true\" date=\"2026-11-08\">" + rows)
        #expect(SearchActivity.region(without) == nil && SearchActivity.label(without)?.string == "Searched the web · 1 source")  // M9.T04 plural form
        var r = WebResults(queries: ["q"], sources: [], evidence: [], evidenceTokens: 0, failed: nil)
        r.region = "fr"
        #expect(WebResultsBlock.render(r).hasPrefix("<web_results untrusted=\"true\" date=\"") && WebResultsBlock.render(r).contains(" region=\"fr\">"))
        // the source: on by default; on + granted → the Mac's region; without permission → nil; off → nil
        SettingsKeys.resetAll()
        let (s0, r0, o0) = (SearchRegionSource.status, SearchRegionSource.region, SearchRegionSource.offerExplainer)
        defer { SearchRegionSource.status = s0; SearchRegionSource.region = r0; SearchRegionSource.offerExplainer = o0
                SettingsKeys.resetAll() }
        final class Count: @unchecked Sendable { var n = 0 }
        let offers = Count()
        SearchRegionSource.offerExplainer = { offers.n += 1 }
        SearchRegionSource.status = { .granted }
        SearchRegionSource.region = { "DE" }
        #expect(SearchRegionSource.live() == "DE", "on by default")
        SearchRegionSource.status = { .denied }
        #expect(SearchRegionSource.live() == nil)
        #expect(offers.n == 0, "granted or denied: nothing to ask")
        // macOS never asked: this search carries no location, and the just-in-time explainer is offered.
        SearchRegionSource.status = { .notDetermined }
        #expect(SearchRegionSource.live() == nil)
        #expect(offers.n == 1)
        // Off (the user's choice, or "Not now"): no location and nothing is offered.
        Defaults[.searchUsesLocation] = false
        SearchRegionSource.status = { .granted }
        #expect(SearchRegionSource.live() == nil)
        SearchRegionSource.status = { .notDetermined }
        #expect(SearchRegionSource.live() == nil)
        #expect(offers.n == 1)
    }

    @Test func searchActivityLabels() {
        let block = "<web_results untrusted=\"true\" date=\"2026-11-04\">\nrule\n\nSources:\n[1] A — a.test — https://a.test/\n[2] B — b.test — https://b.test/\n\n</web_results>"
        let done = ToolActivity(id: "1", tool: "web_search", state: .done, argumentsJSON: #"{"queries":["q1","q2"]}"#, result: block)
        #expect(SearchActivity.label(done)?.string == "Searched the web · 2 sources")
        #expect(SearchActivity.queries(done) == ["q1", "q2"])
        #expect(SearchActivity.label(ToolActivity(id: "2", tool: "web_search", state: .running))?.string == "Searching the web")
        let failed = ToolActivity(id: "3", tool: "web_search", state: .failed, result: "Error: search.failed")
        #expect(SearchActivity.failedAllEngines(failed))
        #expect(SearchActivity.label(failed)?.string == "Couldn't reach search engines. Answered without the web.")
        let read = ToolActivity(id: "4", tool: "read_url", state: .done, argumentsJSON: #"{"url":"https://a.test/"}"#, result: block)
        #expect(SearchActivity.label(read)?.string == "Read a.test")
    }
}

extension CitationPill {
    /// The numbers of every pill link in `text` (tests).
    static func pattern(in text: String) -> [String] {
        let rx = try! NSRegularExpression(pattern: #"\]\(antichat-cite://([0-9,]+)\)"#)
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap {
            ns.substring(with: $0.range(at: 1)).split(separator: ",").prefix(1).map(String.init)
        }
    }
}

// M7.T15 (AT-241 c3; R-241 AC3): "Safe search results" is a Settings key in the app's settings store, off by default,
// and the search code reads that same key; the Tools & Connections row exists with its copy key.
@MainActor
@Suite(.serialized, .isolatedSettings) struct SafeSearchSettingTests {
    @Test func offByDefaultInTheSettingsStoreAndReadByTheSearchCode() {
        Defaults.reset(.safeSearch)
        #expect(Defaults[.safeSearch] == false)
        #expect(Defaults.Keys.safeSearch.name == SafeSearch.defaultsKey)
        #expect(SettingsKeys.defaults[SafeSearch.defaultsKey] == "false")
        let row = SettingsRegistry.row("safeSearch")
        #expect(row?.section == .capabilities && row?.advanced == true && row?.label == CopyKey("set.tools.safeSearch") && row?.key == SafeSearch.defaultsKey)
    }
}
