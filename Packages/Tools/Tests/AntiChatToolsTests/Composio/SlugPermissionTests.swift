// M7.T11 AT-256 (R-256 AC1/AC2): per-slug permission inside COMPOSIO_MULTI_EXECUTE_TOOL, on the 50 write + 50 read
// slugs of `fixtures/web/mcp/composio-write-slugs-50.json` (tools/fixtures/make-composio-slugs.py).
import AntiChatStorage
@testable import AntiChatTools
import Foundation
import Testing

@Suite struct SlugPermissionTests {
    struct Entry: Decodable { var slug: String; var tags: [String] }
    struct Doc: Decodable { var write: [Entry]; var read: [Entry] }
    static let doc: Doc? = (try? Data(contentsOf: ToolsFixtures.url("web/mcp/composio-write-slugs-50.json")))
        .flatMap { try? JSONDecoder().decode(Doc.self, from: $0) }

    static func cache(_ d: Doc) -> SlugPermission.TagCache {
        let c = SlugPermission.TagCache()
        for e in d.write + d.read where !e.tags.isEmpty { c.set(e.slug, .init(tags: e.tags)) }
        return c
    }

    static func batch(_ slugs: [String]) -> String {
        let tools = slugs.map { ["tool_slug": $0, "arguments": ["q": "x"]] as [String: Any] }
        let d = try! JSONSerialization.data(withJSONObject: ["tools": tools, "thought": "t"])
        return String(decoding: d, as: UTF8.self)
    }

    @Test func fixturePresent() throws {
        let d = try #require(Self.doc, "fixtures/web/mcp/composio-write-slugs-50.json missing")
        #expect(d.write.count == 50 && d.read.count == 50)
    }

    /// c2: every write slug asks by default (tagged or by verb, including verbs outside the token list).
    @Test func allFiftyWriteSlugsAskByDefault() throws {
        let d = try #require(Self.doc)
        for c in [Self.cache(d), SlugPermission.TagCache()] {  // with the search tags, and with none (verb rule only)
            let checks = SlugPermission.checks(slugs: d.write.map(\.slug), cache: c, untrustedContext: false) { _ in nil }
            for ch in checks { #expect(ch.decision == .ask(untrusted: false), "\(ch.slug) should ask") }
        }
    }

    @Test func readSlugsRunByDefault() throws {
        let d = try #require(Self.doc)
        let checks = SlugPermission.checks(slugs: d.read.map(\.slug), cache: Self.cache(d), untrustedContext: false) { _ in nil }
        #expect(checks.allSatisfy { $0.decision == .run })
    }

    /// c2: Always allow on GMAIL_SEND_EMAIL writes only that slug's row; the other 49 (and GMAIL_DELETE_MESSAGE) ask.
    @Test func alwaysAllowIsPerSlug() throws {
        let d = try #require(Self.doc)
        var rows: [String: ToolPermissionRecord.Policy] = [:]
        rows[SlugPermission.key("GMAIL_SEND_EMAIL")] = .always
        let checks = SlugPermission.checks(slugs: d.write.map(\.slug), cache: Self.cache(d), untrustedContext: false) { rows[$0] }
        #expect(checks.filter { $0.decision == .run }.map(\.slug) == ["GMAIL_SEND_EMAIL"])
        #expect(checks.filter { $0.decision == .ask(untrusted: false) }.count == 49)
        #expect(checks.first { $0.slug == "GMAIL_DELETE_MESSAGE" }?.decision == .ask(untrusted: false))
        #expect(SlugPermission.key("gmail_send_email") == "composio:GMAIL_SEND_EMAIL")
    }

    /// c1: a mixed batch (1 read + 2 writes) → 2 cards; a blocked slug denies the whole call.
    @Test func mixedBatchAsksPerWriteSlug() throws {
        let d = try #require(Self.doc)
        let slugs = try #require(SlugPermission.slugs(argumentsJSON: Self.batch(["GMAIL_FETCH_EMAILS", "GMAIL_SEND_EMAIL", "SLACK_CHAT_POST_MESSAGE"])))
        #expect(slugs == ["GMAIL_FETCH_EMAILS", "GMAIL_SEND_EMAIL", "SLACK_CHAT_POST_MESSAGE"])
        let checks = SlugPermission.checks(slugs: slugs, cache: Self.cache(d), untrustedContext: false) { _ in nil }
        #expect(checks.filter { if case .ask = $0.decision { true } else { false } }.map(\.slug) == ["GMAIL_SEND_EMAIL", "SLACK_CHAT_POST_MESSAGE"])
        let blocked = SlugPermission.checks(slugs: slugs, cache: Self.cache(d), untrustedContext: false) {
            $0 == SlugPermission.key("SLACK_CHAT_POST_MESSAGE") ? .block : nil
        }
        #expect(blocked.contains { $0.decision == .deny })
    }

    /// NFR-SEC5: with untrusted output in context, an always-allowed write slug asks again; a read still runs.
    @Test func untrustedContextAsksForAlwaysAllowedWrite() throws {
        let d = try #require(Self.doc)
        let checks = SlugPermission.checks(slugs: ["GMAIL_SEND_EMAIL", "GMAIL_FETCH_EMAILS"], cache: Self.cache(d),
                                           untrustedContext: true) { _ in .always }
        #expect(checks[0].decision == .ask(untrusted: true))
        #expect(checks[1].decision == .run)
    }

    @Test func unparseableBatchIsNil() {
        #expect(SlugPermission.slugs(argumentsJSON: "{}") == nil)
        #expect(SlugPermission.slugs(argumentsJSON: #"{"tools":[{"arguments":{}}]}"#) == nil)
        #expect(SlugPermission.slugs(argumentsJSON: "not json") == nil)
    }

    @Test func tagCacheLearnsFromSearchResult() {
        let c = SlugPermission.TagCache()
        c.learn(fromResult: #"{"data":{"results":[{"primary_tool_slugs":["X"],"tools":[{"tool_slug":"FOO_FETCH_BAR","tags":["destructiveHint"]}]}]}}"#)
        #expect(c.hints("foo_fetch_bar")?.destructive == true)
        #expect(SlugPermission.isWrite("FOO_FETCH_BAR", hints: c.hints("FOO_FETCH_BAR")))  // tags win over the read verb
    }
}
