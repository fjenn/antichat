// AT-297 (R-297 AC2, in-process half): N gated requests → N `network_activity` rows with the right category, host
// and bytes; incognito requests produce none. (The proxy-log half is AT-209, M2.T03.) The events are taken
// through an observer filtered by this test's turn id, so parallel suites never mix rows in.
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatPlatform

@Suite("NetworkActivityStoreTests") struct NetworkActivityStoreTests {
    @Test func testActivityRowsMatchRequests() async throws {
        let server = try TestHTTPServer(body: Data(repeating: 65, count: 1000))
        let db = try AppDatabase.inMemory()
        let turn = UUID().uuidString
        let token = NetworkGate.addObserver { e in if e.turnID == turn { NetworkActivityStore.write(e, to: db) } }
        defer { NetworkGate.removeObserver(token) }
        let plan: [NetworkCategory] = [.models, .catalog, .search, .models, .updates]
        try await TurnContext.$requestID.withValue(turn) {
            for (i, c) in plan.enumerated() {
                _ = try await NetworkGate.gated(c).data(from: server.baseURL.appendingPathComponent("r\(i)"))
            }
        }
        // didFinishCollecting may land just after the response; wait for all N.
        for _ in 0..<100 where try NetworkActivityRecord.recent(db, since: .distantPast).count < plan.count {
            try await Task.sleep(for: .milliseconds(20))
        }
        let rows = try NetworkActivityRecord.recent(db, since: .distantPast)
        #expect(rows.count == plan.count)
        #expect(rows.map(\.category).sorted() == plan.map(\.rawValue).sorted())
        for r in rows {
            #expect(r.host == "127.0.0.1" && r.outcome == "ok")
            #expect(r.bytes >= 1000, "bytes \(r.bytes) must include the 1000-byte body")
        }
    }

    @Test func incognitoWritesNoRow() async throws {
        let server = try TestHTTPServer()
        let db = try AppDatabase.inMemory()
        let turn = UUID().uuidString
        let seen = Seen()
        let token = NetworkGate.addObserver { e in
            if e.turnID == turn { seen.add(); NetworkActivityStore.write(e, to: db) }
        }
        defer { NetworkGate.removeObserver(token) }
        let s = NetworkGate.incognitoSession(for: .search)
        defer { s.invalidateAndCancel() }
        try await TurnContext.$requestID.withValue(turn) {
            _ = try await s.data(for: NetworkGate.tag(URLRequest(url: server.baseURL), category: .search))
        }
        for _ in 0..<100 where seen.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(seen.count == 1)  // the turn ledger still sees it (globe chip) …
        #expect(try NetworkActivityRecord.recent(db, since: .distantPast).isEmpty)  // … but nothing is persisted
    }

    @Test func installRoutesTheSinkAndPrunes() throws {
        let db = try AppDatabase.inMemory()
        var old = NetworkActivityRecord(ts: Date().addingTimeInterval(-8 * 24 * 3600), category: "models", host: "h", bytes: 1, outcome: "ok")
        try db.write { try old.insert($0) }
        let previous = NetworkGate.activitySink
        NetworkActivityStore.install(database: db)
        defer { NetworkGate.activitySink = previous }
        #expect(try NetworkActivityRecord.recent(db, since: .distantPast).filter { $0.host == "h" }.isEmpty)
        NetworkGate.activitySink?(NetworkEvent(category: .catalog, host: "antichat.app", bytes: 5, outcome: .ok, incognito: false))
        #expect(try NetworkActivityRecord.recent(db, since: .distantPast).filter { $0.host == "antichat.app" }.count == 1)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
