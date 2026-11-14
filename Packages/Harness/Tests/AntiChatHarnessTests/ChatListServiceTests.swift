// ChatListService (M1.T07 step 6): every chat operation writes through ChatRepository and the sidebar observation
// delivers the change; with 10k chats the observation stays ≤ 100 ms (failure mode: page to 200 rows).
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@MainActor
@Suite struct ChatListServiceTests {
    /// Waits for the next sidebar value satisfying `cond`; returns the seconds from `start`.
    func observe(_ service: ChatListService, limit: Int = ChatListService.sidebarPageSize,
                 after mutate: () throws -> Void, until cond: @escaping ([ChatSummary]) -> Bool) async throws -> Double {
        var latest: [ChatSummary] = []
        var hit: ContinuousClock.Instant?
        let token = service.observeSidebar(limit: limit) { rows in
            latest = rows
            if hit == nil, cond(rows) { hit = .now }
        }
        defer { token.cancel() }
        // Initial value.
        for _ in 0..<200 where latest.isEmpty && hit == nil { try await Task.sleep(for: .milliseconds(5)) }
        hit = nil
        let start = ContinuousClock.now
        try mutate()
        for _ in 0..<400 where hit == nil { try await Task.sleep(for: .milliseconds(2)) }
        let h = try #require(hit)
        let d = h - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test func operationsReachTheSidebar() async throws {
        let s = try ChatListService.inMemory()
        let a = try s.create(title: "Alpha")
        let b = try s.create(title: "Beta")
        _ = try await observe(s, after: { try s.rename(a.id, to: "Alpha 2") }) { $0.contains { $0.title == "Alpha 2" } }
        _ = try await observe(s, after: { try s.setPinned(b.id, true) }) { $0.first?.id == b.id && $0.first?.pinned == true }
        _ = try await observe(s, after: { try s.archive([a.id]) }) { !$0.contains { $0.id == a.id } }
        _ = try await observe(s, after: { try s.unarchive(a.id) }) { $0.contains { $0.id == a.id } }
        _ = try await observe(s, after: { try s.delete([a.id, b.id]) }) { $0.isEmpty }
        #expect(try s.chat(a.id) == nil)
    }

    @Test func blankRenameIsIgnored() throws {
        let s = try ChatListService.inMemory()
        let a = try s.create(title: "Keep")
        try s.rename(a.id, to: "   ")
        #expect(try s.chat(a.id)?.title == "Keep")
    }

    @Test func transcriptAndExport() throws {
        let s = try ChatListService.inMemory()
        let c = try s.create(title: "Trip: Rome/Paris")
        try s.appendUserMessage(c.id, text: "Plan a trip")
        try s.appendAssistantMessage(c.id, text: "Day 1: Rome")
        let t = try s.transcript(c.id)
        #expect(t.map(\.role) == [.user, .assistant])
        #expect(t.map(\.text) == ["Plan a trip", "Day 1: Rome"])
        let md = String(decoding: try s.export(c.id, as: .markdown), as: UTF8.self)
        #expect(md == "# Trip: Rome/Paris\n\n## User\n\nPlan a trip\n\n## Assistant\n\nDay 1: Rome\n")
        let json = try s.export(c.id, as: .json)
        let doc = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(doc?["schema"] as? String == "antichat.tree.v1")
        #expect(ChatListService.exportFileName(title: "Trip: Rome/Paris", format: .markdown) == "Trip  Rome Paris.md")
        #expect(ChatListService.exportFileName(title: "", format: .json) == "Chat.json")
    }

    /// Step 6 budget with the 10k-chat fixture size: a rename at the top of the list reaches the observer ≤ 100 ms.
    @Test func tenThousandChatsUpdateWithin100ms() async throws {
        let s = try ChatListService.inMemory()
        try s.database.write { db in
            let base = Date().addingTimeInterval(-86_400 * 30)
            for i in 0..<10_000 {
                try ChatRecord(title: "Chat \(i)", titleState: .auto,
                               createdAt: base.addingTimeInterval(Double(i) * 60)).insert(db)
            }
        }
        let top = try #require(try s.chat(ChatRepository(s.database).sidebar(limit: 1)[0].id))
        // Median of 7, not the worst: under the parallel `make test-unit` load a single sample can stall on the
        // scheduler (flake fixed once, D-025 brief). The p95 bar over 50 operations is `make perf METRIC=sidebarUpdate`.
        var samples: [Double] = []
        for i in 0..<7 {
            samples.append(try await observe(s, after: { try s.rename(top.id, to: "Renamed \(i)") }) {
                $0.first?.title == "Renamed \(i)"
            })
        }
        let median = samples.sorted()[samples.count / 2]
        #expect(median <= 0.1, "median sidebar update \(median) s (samples \(samples))")
        print("sidebarUpdate 10k median of 7: \(String(format: "%.1f", median * 1000)) ms")
    }
}
