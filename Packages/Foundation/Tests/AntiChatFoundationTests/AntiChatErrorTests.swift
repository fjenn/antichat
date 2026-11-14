// M1.T05 step 7: every M1 AntiChatError code maps to a copy-deck key of the same name (except
// context.tooLarge → ctx.tooLarge), and the error stays Codable across the M0 → M1 shape change.
import Foundation
import Testing
@testable import AntiChatFoundation

@Suite struct AntiChatErrorTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Copy-deck keys = backticked dotted ids in the first column of each table row (tools/ci/copy-sync.py).
    static func deckKeys() throws -> Set<String> {
        let deck = repoRoot.appendingPathComponent("docs/research/10-architecture/design-system/copy-deck.md")
        let text = try String(contentsOf: deck, encoding: .utf8)
        var keys = Set<String>()
        for line in text.split(separator: "\n") where line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
            guard cells.count > 1 else { continue }
            let parts = cells[1].split(separator: "`", omittingEmptySubsequences: false)
            for (i, p) in parts.enumerated() where i % 2 == 1 && p.contains(".") && !p.hasPrefix(".") {
                keys.insert(String(p))
            }
        }
        return keys
    }

    @Test func everyCodeHasACopyDeckKey() throws {
        let keys = try Self.deckKeys()
        #expect(keys.count > 100, "copy deck not found or empty at \(Self.repoRoot.path)")
        for c in AntiChatError.Code.allCases {
            #expect(keys.contains(c.userMessageKey), "\(c.rawValue) → \(c.userMessageKey) missing in copy-deck.md")
        }
        #expect(keys.contains("engine.error") && keys.contains("model.error"), "generic fallbacks (A-M1-T02b)")
    }

    @Test func m1CodeList() {
        #expect(AntiChatError.Code.allCases.map(\.rawValue) == [
            "engine.restarted", "engine.crashLoop", "engine.versionMismatch", "engine.stalled", "engine.emptyReply",
            "model.notEnoughMemory",
            "model.usingLighter", "model.missing", "model.corrupt", "context.tooLarge", "tool.failed", "tool.denied",
            "tool.loopLimit", "storage.newerVersion",
        ])
        #expect(AntiChatError.Code.contextTooLarge.userMessageKey == "ctx.tooLarge")
        #expect(AntiChatError.Code.engineRestarted.userMessageKey == "engine.restarted")
    }

    @Test func codeSplitsIntoDomainAndShortCode() {
        let e = AntiChatError(.modelNotEnoughMemory, detail: "9.5 GB")
        #expect(e.domain == .model)
        #expect(e.code == "notEnoughMemory")
        #expect(e.fullCode == "model.notEnoughMemory")
        #expect(e.known == .modelNotEnoughMemory)
        #expect(e.is(.modelNotEnoughMemory))
        #expect(e.recovery == [.retry])
        #expect(AntiChatError(.contextTooLarge).domain == .context)
        #expect(AntiChatError.engine("internal").known == nil)
    }

    @Test func roundTripsAndDecodesM0Payloads() throws {
        let e = AntiChatError(.modelCorrupt, detail: "x", recovery: [.redownload(slot: "chat-9b-q4"), .openSettings(path: "models")])
        let back = try JSONDecoder().decode(AntiChatError.self, from: JSONEncoder().encode(e))
        #expect(back == e)
        // M0 shape (no `recovery`): still decodes, with no actions.
        let m0 = #"{"domain":"engine","code":"restarted","userMessageKey":"engine.restarted","detail":"d"}"#
        let old = try JSONDecoder().decode(AntiChatError.self, from: Data(m0.utf8))
        #expect(old.is(.engineRestarted))
        #expect(old.recovery.isEmpty)
    }

    @Test func typedIDsAreDistinctAndCodeAsBareUUIDs() throws {
        let u = UUID()
        let chat = ChatID(u)
        let data = try JSONEncoder().encode([chat])
        #expect(String(decoding: data, as: UTF8.self) == "[\"\(u.uuidString)\"]")
        #expect(try JSONDecoder().decode([ChatID].self, from: data) == [chat])
        #expect(MessageID(uuidString: u.uuidString)?.raw == u)
    }
}
