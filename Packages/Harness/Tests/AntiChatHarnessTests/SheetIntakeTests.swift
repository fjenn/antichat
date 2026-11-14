// M6.T07 (R-272 AC1 XLS, A-M6-10): legacy.xls → XLSAdapter (libxls) → SheetLoader → typed DuckDB tables (2 sheets,
// 500 rows: numbers, dates, date-times, booleans, text), and the tier caps from tier-budgets.json reach the store.
//   make test-unit FILTER=SheetIntakeTests
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct SheetIntakeTests {
    static let fixtures: URL = {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty { return URL(fileURLWithPath: env) }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        return dir.appendingPathComponent("fixtures")
    }()

    @Test func legacyXLSTyped() async throws {
        let chat = "xls-\(UUID().uuidString)"
        defer { DuckDBStore.close(chatID: chat) }
        let store = try SheetIntake.store(chatID: chat, tier: "T0")
        #expect(store.config.memoryMB == 256)
        let loaded = try await SheetIntake.load(url: Self.fixtures.appendingPathComponent("docs/office/legacy.xls"),
                                                kind: .xls, into: store, tier: "T0")
        #expect(loaded.tables.map(\.name) == ["Orders", "Staff"])
        #expect(loaded.tables.map(\.rowCount) == [450, 50])
        #expect(loaded.tables[0].columns.map(\.type) == [.bigint, .date, .varchar, .double, .boolean, .timestamp])
        #expect(loaded.tables[1].columns.map(\.type) == [.varchar, .date, .bigint])
        let r = try store.stringRows("SELECT count(*), min(order_date) >= DATE '2025-01-01', max(packed_at) < TIMESTAMP '2026-09-01' FROM Orders").rows[0]
        #expect(r == ["450", "true", "true"])
        #expect(loaded.profile.contains("Table \"Orders\" from legacy.xls › Orders: 450 rows"))
        #expect(TokenCount.estimate(loaded.profile) <= 1500, "T0 cap")
    }

    @Test func tierCaps() {
        let b = TierBudgets.shared
        #expect(["T0", "T1", "T2", "T3", "T4"].map(b.duckDBMemoryMB) == [256, 512, 1024, 2048, 2048])
        #expect(["T0", "T1", "T3"].map(b.sheetProfileTokens) == [1500, 3000, 3000])
    }
}

enum TokenCount { static func estimate(_ s: String) -> Int { (s.count + 3) / 4 } }
