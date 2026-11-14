// M6.T07 step 3 + 6 (R-272 AC1, AT-272 check 1): the per-chat DuckDB opens locked down — external access off (no
// network URL, no local file read/write, no ATTACH), no extension install/load, settings locked — and nothing reaches
// the network (NetworkGate observer sees 0 events).
//   make test-unit FILTER=DuckDBStoreTests
import AntiChatNetwork
import Foundation
import Testing
@testable import AntiChatTools

@Suite(.serialized) struct DuckDBStoreTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    @Test func testExternalAccessDenied() throws {
        let events = Counter()
        // only this test's hosts: the observer is process-wide and other suites run in parallel (gate events of
        // their own search/relay tests made this flaky)
        let token = NetworkGate.addObserver { e in if e.host.contains("example.com") || e.host.contains("duckdb") { events.bump() } }
        defer { NetworkGate.removeObserver(token) }
        let store = try DuckDBStore(chatID: "ext-\(UUID().uuidString)", config: .init(memoryMB: 256, threads: 1))
        try store.query("CREATE TABLE t AS SELECT 1 AS a")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("duck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let local = tmp.appendingPathComponent("in.csv")
        try "a,b\n1,2\n".write(to: local, atomically: true, encoding: .utf8)
        let denied = [
            "SELECT * FROM read_csv('https://example.com/x.csv')",
            "SELECT * FROM read_csv('\(local.path)')",  // local reads too: SheetLoader parses CSV in Swift
            "INSTALL httpfs",
            "LOAD httpfs",
            "COPY t TO '\(tmp.appendingPathComponent("x.csv").path)'",
            "ATTACH '\(tmp.appendingPathComponent("y.db").path)'",
            "SET enable_external_access = true",
            "SET memory_limit = '8GB'",
            "SET autoinstall_known_extensions = true",
        ]
        for sql in denied {
            #expect(throws: DuckDBStoreError.self, "\(sql) must fail") { try store.query(sql) }
        }
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("x.csv").path))
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("y.db").path))
        #expect(events.count == 0, "no network event")
    }

    @Test func settingsAppliedAndLockedLast() throws {
        let settings = DuckDBStore.settings(.init(memoryMB: 512, threads: 2))
        #expect(settings.last?.0 == "lock_configuration")
        let store = try DuckDBStore(chatID: "cfg-\(UUID().uuidString)", config: .init(memoryMB: 512, threads: 2))
        let r = try store.stringRows("""
            SELECT name, value FROM duckdb_settings() WHERE name IN
            ('enable_external_access','autoinstall_known_extensions','autoload_known_extensions','threads','lock_configuration','memory_limit')
            ORDER BY name
            """).rows
        let v = Dictionary(uniqueKeysWithValues: r.map { ($0[0] ?? "", $0[1] ?? "") })
        #expect(v["enable_external_access"] == "false")
        #expect(v["autoinstall_known_extensions"] == "false")
        #expect(v["autoload_known_extensions"] == "false")
        #expect(v["lock_configuration"] == "true")
        #expect(v["threads"] == "2")
        #expect(v["memory_limit"]?.hasPrefix("488") == true || v["memory_limit"]?.hasPrefix("512") == true,
                "512MB as DuckDB prints it (MiB): \(v["memory_limit"] ?? "nil")")
    }

    @Test func perChatRegistryAndThreads() throws {
        let a = try DuckDBStore.open(chatID: "reg-a")
        #expect(try DuckDBStore.open(chatID: "reg-a") === a)
        #expect(try DuckDBStore.open(chatID: "reg-b") !== a)
        DuckDBStore.close(chatID: "reg-a"); DuckDBStore.close(chatID: "reg-b")
        #expect((1...4).contains(DuckDBStore.defaultThreads))
    }

    @Test func tableNamesSanitisedAndUnique() throws {
        let s = try DuckDBStore(chatID: "names-\(UUID().uuidString)")
        #expect(s.claimTableName("Q1 Budget (draft)") == "Q1_Budget_draft")
        #expect(s.claimTableName("Q1 Budget (draft)") == "Q1_Budget_draft_2")
        #expect(s.claimTableName("2026") == "t_2026")
        #expect(s.claimTableName("Übersicht") == "bersicht")
        #expect(s.claimTableName("***") == "sheet")
    }
}
