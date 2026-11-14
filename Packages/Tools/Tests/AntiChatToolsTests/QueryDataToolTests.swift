// M6.T08 (R-272 AC2, AT-272 check 2): the read-only guard, the 200-row cap + data_ref with every row, and the 10 s
// timeout (duckdb_interrupt) on a streaming 1e13-row scan (the AT's cross join fails fast on memory_limit, see
// crossJoinFailsFast); the store answers afterwards.
//   make test-unit FILTER=QueryDataToolTests
import Foundation
import Testing
@testable import AntiChatTools

@Suite(.serialized) struct QueryDataToolTests {
    static func store() async throws -> (DuckDBStore, String) {
        let chat = "q-\(UUID().uuidString)"
        let s = try DuckDBStore(chatID: chat)
        _ = try await SheetLoader.load(xlsx: ToolsFixtures.url("docs/office/budget-20k.xlsx"), into: s)
        return (s, chat)
    }

    @Test func readOnlyGuard() async throws {
        let (s, chat) = try await Self.store()
        let rejected: [(String, QueryDataError)] = [
            ("INSERT INTO Categories VALUES ('x', 1, 'y')", .notReadOnly("INSERT")),
            ("UPDATE Categories SET budget = 0", .notReadOnly("UPDATE")),
            ("DELETE FROM Categories", .notReadOnly("DELETE")),
            ("CREATE TABLE x AS SELECT 1", .notReadOnly("CREATE")),
            ("DROP TABLE Categories", .notReadOnly("DROP")),
            ("ATTACH '/tmp/y.db'", .notReadOnly("ATTACH")),
            ("INSTALL httpfs", .notReadOnly("LOAD")),
            ("LOAD httpfs", .notReadOnly("LOAD")),
            ("SET threads = 8", .notReadOnly("SET")),
            ("PRAGMA enable_profiling", .notReadOnly("PRAGMA")),
            ("SELECT 1; DROP TABLE Categories", .oneStatement(2)),
        ]
        for (sql, want) in rejected {
            await #expect(throws: want, "\(sql)") { _ = try await QueryDataTool.run(sql: sql, store: s, chatID: chat) }
        }
        // Bound at prepare time (file access is off) or unparsable: still a tool error, never run.
        for sql in ["COPY Categories TO '/tmp/x.csv'", "SELEC 1",
                    "PIVOT Transactions ON region USING sum(amount)"] {  // implicit PIVOT = CREATE TYPE + SELECT
            await #expect(throws: QueryDataError.self, "\(sql)") { _ = try await QueryDataTool.run(sql: sql, store: s, chatID: chat) }
        }
        #expect(try s.stringRows("SELECT count(*) FROM Categories").rows[0][0] == "12", "nothing changed")
        for sql in ["WITH t AS (SELECT region, sum(amount) s FROM Transactions GROUP BY 1) SELECT * FROM t ORDER BY s DESC",
                    "SUMMARIZE Transactions", "DESCRIBE Transactions",
                    "PIVOT Transactions ON region IN ('North', 'South', 'East', 'West') USING sum(amount) GROUP BY category",
                    "FROM Categories SELECT category", "SELECT 1;"] {
            let r = try await QueryDataTool.run(sql: sql, store: s, chatID: chat)
            #expect(r.rowCount > 0, "\(sql)")
        }
    }

    @Test func rowCapAndDataRef() async throws {
        let (s, chat) = try await Self.store()
        let r = try await QueryDataTool.run(sql: "SELECT txn_id, date, amount FROM Transactions ORDER BY txn_id", store: s, chatID: chat)
        #expect(r.rows.count == 200 && r.rowCount == 20_000 && r.truncated)
        #expect(r.types == ["BIGINT", "DATE", "DOUBLE"])
        #expect(r.dataRef.hasPrefix("qr_"))
        let ref = try #require(DataRefStore.shared.get(chatID: chat, id: r.dataRef))
        #expect(ref.rows.count == 20_000 && !ref.truncated)
        #expect(ref.rows.last?.first == "20000")
        let text = QueryDataTool.resultText(r, file: "budget-20k.xlsx")
        #expect(text.contains("(showing 200 of 20000 rows)"))
        let sum = try #require(QueryDataTool.summary(ofResult: text))
        #expect(sum == .init(row_count: 20_000, file: "budget-20k.xlsx", truncated: true, data_ref: r.dataRef))
        #expect(QueryDataTool.files(in: "select * from transactions t join Categories c using (category)",
                                    tables: try await SheetLoader.load(csv: ToolsFixtures.url("docs/office/notes.csv"), into: s)
                                        + [LoadedTable(name: "Transactions", file: "budget-20k.xlsx", sheet: "Transactions",
                                                       columns: [], rowCount: 0)]) == ["budget-20k.xlsx"])
        #expect(QueryDataTool.groupingNote(r) == nil, "not grouped")
        let daily = try await QueryDataTool.run(sql: "SELECT strftime(date, '%Y-%m') AS month, sum(amount) AS t FROM Transactions GROUP BY date",
                                                store: s, chatID: chat)
        #expect(QueryDataTool.resultText(daily).contains("Note: \"month\" repeats"), "grouped finer than the label column")
        let monthly = try await QueryDataTool.run(sql: "SELECT strftime(date, '%Y-%m') AS month, sum(amount) AS t FROM Transactions GROUP BY 1",
                                                  store: s, chatID: chat)
        #expect(QueryDataTool.groupingNote(monthly) == nil)
        #expect(QueryDataTool.monthLabelNote(monthly) == nil, "zero-padded YYYY-MM")
        let unpadded = try await QueryDataTool.run(
            sql: "SELECT year(date) || '-' || month(date) AS month, sum(amount) AS t FROM Transactions GROUP BY 1",
            store: s, chatID: chat)
        #expect(QueryDataTool.resultText(unpadded).contains("months without a leading zero"), "2025-1 is not YYYY-MM")
        let cast = try await QueryDataTool.run(
            sql: "SELECT date::VARCHAR(7) AS month, sum(amount) AS t FROM Transactions GROUP BY date ORDER BY date",
            store: s, chatID: chat)
        #expect(((cast.rows.first?.first) ?? nil)?.count == 10, "DuckDB keeps the whole date")
        #expect(QueryDataTool.resultText(cast).contains("DuckDB ignores the length in VARCHAR(7)"))
        #expect(QueryDataTool.castLengthNote(monthly) == nil, "no cast")
        let fits = try await QueryDataTool.run(sql: "SELECT left(strftime(date, '%Y-%m'), 7)::VARCHAR(7) AS m FROM Transactions LIMIT 3",
                                               store: s, chatID: chat)
        #expect(QueryDataTool.castLengthNote(fits) == nil, "values fit the length")
        let one = try await QueryDataTool.run(sql: "SELECT round(sum(amount), 2) AS total FROM Transactions", store: s, chatID: chat)
        #expect(one.rows.count == 1 && !one.truncated && one.columns == ["total"])
    }

    /// The AT's cross join cannot run here at all: DuckDB materialises the build side, hits `memory_limit` and, as its
    /// temp directory is a denied file access (no disk spill, contract 4), fails fast — a tool error, not a hang.
    @Test func crossJoinFailsFast() async throws {
        let (s, chat) = try await Self.store()
        // It ends in a tool error (the memory limit, or the 10 s deadline on a host so loaded that the limit is reached
        // late: load ~115 stretched it past the deadline), never rows and never a hang. No wall-clock ordering asserted.
        do {
            _ = try await QueryDataTool.run(sql: "SELECT count(*) FROM range(1e12::BIGINT) a, range(1e12::BIGINT) b",
                                            store: s, chatID: chat)
            Issue.record("the cross join returned rows")
        } catch is QueryDataError {
        }
    }

    /// A streaming query that would run for hours: interrupted at the 10 s deadline.
    @Test func timeoutInterruptsAtTenSeconds() async throws {
        let (s, chat) = try await Self.store()
        let t0 = ContinuousClock.now
        await #expect(throws: QueryDataError.timeout(seconds: 10)) {
            _ = try await QueryDataTool.run(sql: "SELECT sum(hash(i)) FROM range(1e13::BIGINT) t(i)", store: s, chatID: chat)
        }
        let took = ContinuousClock.now - t0
        // AT-272's 10 s ± 0.5 s is the AT's (quiet machine). Here: the query (hours of work) was interrupted — the
        // throw above — and not before the deadline; sleeps and deadlines only give lower bounds under load.
        #expect(took >= .seconds(10), "timeout at 10 s: \(took)")
        // The store (and the query connection) still answer.
        let r = try await QueryDataTool.run(sql: "SELECT count(*) FROM Monthly", store: s, chatID: chat)
        #expect(r.rows[0][0] == "24")
    }

    @Test func shortTimeoutIsDeterministic() async throws {
        let (s, chat) = try await Self.store()
        await #expect(throws: QueryDataError.timeout(seconds: 0)) {
            _ = try await QueryDataTool.run(sql: "SELECT sum(hash(i)) FROM range(1e13::BIGINT) t(i)",
                                            store: s, chatID: chat, timeout: .milliseconds(300))
        }
    }
}
