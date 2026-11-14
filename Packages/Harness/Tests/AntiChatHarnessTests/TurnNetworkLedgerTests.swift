// AT-209 AC5 (R-209), harness half: events tagged with an open turn's id are collected once per host in
// first-contact order; events for other turns, or after the turn ended, are dropped; a turn without network use
// returns nil (no chip). The gate → TurnContext tagging is covered by NetworkActivityStoreTests.
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatHarness

struct FakeEventSource: NetworkEventSource {
    final class Box: @unchecked Sendable { var handler: (@Sendable (TurnNetworkEvent) -> Void)? }
    let box = Box()
    func observe(_ handler: @escaping @Sendable (TurnNetworkEvent) -> Void) -> any Sendable { box.handler = handler; return box }
    func send(_ turn: String, _ host: String, _ category: String = "search") {
        box.handler?(TurnNetworkEvent(turnID: turn, host: host, category: category))
    }
}

@Suite("TurnNetworkLedgerTests") struct TurnNetworkLedgerTests {
    @Test func collectsHostsPerTurn() {
        let ledger = TurnNetworkLedger()
        let src = FakeEventSource()
        ledger.connect(src)
        ledger.begin("a")
        ledger.begin("b")
        src.send("a", "example.org")
        src.send("a", "cdn.example.org")
        src.send("a", "example.org")
        src.send("b", "other.net")
        src.send("zzz", "ignored.net")
        #expect(ledger.end("a")?.map(\.host) == ["example.org", "cdn.example.org"])
        src.send("a", "late.net")
        #expect(ledger.end("a") == nil)
        #expect(ledger.end("b")?.map(\.host) == ["other.net"])
    }

    @Test func noNetworkMeansNoChip() {
        let ledger = TurnNetworkLedger()
        ledger.connect(FakeEventSource())
        ledger.begin("quiet")
        #expect(ledger.end("quiet") == nil)
    }

    @Test func turnContextIsTaskLocal() async {
        #expect(TurnContext.requestID == nil)
        await TurnContext.$requestID.withValue("t1") {
            #expect(TurnContext.requestID == "t1")
            await Task { #expect(TurnContext.requestID == "t1") }.value  // child tasks inherit it
        }
    }
}
