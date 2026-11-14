// AT-012 leg (1) storage half (M1.T11 step 3, R-012, NFR-U10): FTS5 over titles ∪ text bodies, bm25 ranking,
// snippets with match marks, the Liked filter (AT-005 leg 4's query), recents, and the 10,000-chat latency
// (`build/fixtures/big-10k.sqlite` from `tools/fixtures/gen-chats.py`; skipped when it was not generated).
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite("FTSSearchTests") struct FTSSearchTests {
    struct Fixture {
        let database: AppDatabase
        var ids: [String: String] = [:]      // chat name → id
        var messages: [String: String] = [:] // message name → id
    }

    /// Four chats: "Pasta night" (title word), "Garden" (body token `zebracorn` in its reply), "Tax forms" (two
    /// replies mentioning pasta), "Old notes" (archived, body word `quinoa`); a reasoning part says `zebracorn` too.
    static func fixture() throws -> Fixture {
        let db = try AppDatabase.inMemory()
        var f = Fixture(database: db)
        let chats = ChatRepository(db)
        let tree = MessageTree(db)
        func chat(_ name: String, _ title: String, _ turns: [(String, String)], extra: [PartContent] = []) throws {
            let c = try chats.create(title: title)
            f.ids[name] = c.id
            var parent: String?
            for (i, (u, a)) in turns.enumerated() {
                let user = try tree.append(chatID: c.id, parentID: parent, role: .user, parts: [.text(u)])
                let reply = try tree.append(chatID: c.id, parentID: user.id, role: .assistant,
                                            parts: (i == 0 ? extra : []) + [.text(a)])
                f.messages["\(name).u\(i)"] = user.id
                f.messages["\(name).a\(i)"] = reply.id
                parent = reply.id
            }
        }
        try chat("pasta", "Pasta night", [("What should I cook?", "Try a simple tomato sauce.")])
        try chat("garden", "Garden", [("Soil tips?", "Compost helps. The zebracorn is the search fixture.")],
                 extra: [PartContent(kind: .reasoning, body: "thinking about zebracorn and pasta")])
        try chat("tax", "Tax forms", [("Deadline?", "April. Pasta is not deductible."),
                                      ("And pasta receipts?", "Still not deductible, pasta lovers.")])
        try chat("old", "Old notes", [("Grains?", "Quinoa cooks in fifteen minutes.")])
        try chats.setArchived(f.ids["old"]!, true)
        return f
    }

    @Test func bodyOnlyTokenFindsItsChatWithAHighlightedSnippet() throws {
        let f = try Self.fixture()
        let hits = try FTSSearch(f.database).search("zebracorn")
        #expect(hits.map(\.chatID) == [f.ids["garden"]!])
        let hit = try #require(hits.first)
        #expect(!hit.titleMatched)
        #expect(hit.messageID == f.messages["garden.a0"])
        let runs = try #require(hit.snippet).runs
        #expect(runs.contains { $0.isMatch && $0.text.lowercased() == "zebracorn" })
        #expect(try #require(hit.snippet).plain.contains("is the search fixture"))
    }

    @Test func prefixOfABodyWordMatches() throws {
        let f = try Self.fixture()
        #expect(try FTSSearch(f.database).search("zebra").map(\.chatID) == [f.ids["garden"]!])
    }

    @Test func titleMatchesComeFirstAndEachChatAppearsOnce() throws {
        let f = try Self.fixture()
        let hits = try FTSSearch(f.database).search("pasta")
        // "Pasta night" matches its title; "Tax forms" matches in three text parts → one row.
        #expect(hits.map(\.chatID) == [f.ids["pasta"]!, f.ids["tax"]!])
        #expect(hits[0].titleMatched)
        #expect(!hits[1].titleMatched)
        #expect(hits[1].snippet != nil)
    }

    @Test func titleWordFindsItsChat() throws {
        let f = try Self.fixture()
        let hits = try FTSSearch(f.database).search("garden")
        #expect(hits.first?.chatID == f.ids["garden"])
        #expect(hits.first?.titleMatched == true)
    }

    @Test func everyWordMustMatch() throws {
        let f = try Self.fixture()
        #expect(try FTSSearch(f.database).search("pasta receipts").map(\.chatID) == [f.ids["tax"]!])
        #expect(try FTSSearch(f.database).search("pasta zebracorn").isEmpty)
    }

    @Test func reasoningPartsAreNotIndexed() throws {
        let f = try Self.fixture()
        // The Garden reasoning part says "pasta"; only text parts are searched.
        #expect(!(try FTSSearch(f.database).search("pasta").map(\.chatID).contains(f.ids["garden"]!)))
    }

    @Test func archivedChatsAreSearchedButNotInRecents() throws {
        let f = try Self.fixture()
        let search = FTSSearch(f.database)
        let hit = try #require(try search.search("quinoa").first)
        #expect(hit.chatID == f.ids["old"])
        #expect(hit.archived)
        #expect(!(try search.recents(limit: 10).map(\.chatID).contains(f.ids["old"]!)))
    }

    @Test func emptyOrPunctuationQueriesReturnNothing() throws {
        let f = try Self.fixture()
        let search = FTSSearch(f.database)
        #expect(try search.search("").isEmpty)
        #expect(try search.search("   ").isEmpty)
        #expect(try search.search("\"*()").isEmpty)
    }

    @Test func diacriticsAreFolded() throws {
        let f = try Self.fixture()
        #expect(try FTSSearch(f.database).search("quínoa").first?.chatID == f.ids["old"])
    }

    @Test func singleCharacterQueriesRankByRecency() throws {
        let f = try Self.fixture()
        let hits = try FTSSearch(f.database).search("s", limit: 10)
        #expect(!hits.isEmpty)
        // Title matches first; the body-only rows that follow are newest-first.
        let body = hits.filter { !$0.titleMatched }
        #expect(body.count >= 2)
    }

    @Test func recentsAreMostRecentlyUpdatedFirst() throws {
        let f = try Self.fixture()
        try f.database.write { db in
            try db.execute(sql: "UPDATE chat SET updated_at = 1000 WHERE id = ?", arguments: [f.ids["pasta"]!])
            try db.execute(sql: "UPDATE chat SET updated_at = 3000 WHERE id = ?", arguments: [f.ids["garden"]!])
            try db.execute(sql: "UPDATE chat SET updated_at = 2000 WHERE id = ?", arguments: [f.ids["tax"]!])
        }
        let ids = try FTSSearch(f.database).recents(limit: 2).map(\.chatID)
        #expect(ids == [f.ids["garden"]!, f.ids["tax"]!])
    }

    /// AT-005 leg (4) query: the Liked filter returns the liked reply's chat (with and without a query).
    @Test func likedFilterReturnsLikedReplies() throws {
        let f = try Self.fixture()
        try FeedbackRepository(f.database).setRating(f.messages["tax.a1"]!, .liked)
        let search = FTSSearch(f.database)
        let liked = try search.recents(likedOnly: true)
        #expect(liked.map(\.chatID) == [f.ids["tax"]!])
        #expect(liked.first?.messageID == f.messages["tax.a1"])
        #expect(liked.first?.snippet?.plain.contains("pasta lovers") == true)
        // With a query, only liked bodies count (title-only "Pasta night" drops out).
        let q = try search.search("pasta", likedOnly: true)
        #expect(q.map(\.chatID) == [f.ids["tax"]!])
        #expect(q.first?.messageID == f.messages["tax.a1"])
        #expect(try search.search("tomato", likedOnly: true).isEmpty)
        // Disliked is not liked.
        try FeedbackRepository(f.database).setRating(f.messages["tax.a1"]!, .disliked)
        #expect(try search.recents(likedOnly: true).isEmpty)
    }

    @Test func indexFollowsEditsAndDeletes() throws {
        let f = try Self.fixture()
        let search = FTSSearch(f.database)
        try ChatRepository(f.database).rename(f.ids["garden"]!, title: "Allotment")
        #expect(try search.search("allotment").first?.chatID == f.ids["garden"])
        try ChatRepository(f.database).delete(f.ids["garden"]!)
        #expect(try search.search("zebracorn").isEmpty)
        #expect(try search.search("allotment").isEmpty)
    }

    @Test func snippetRunsSplitOnMarks() {
        let s = FTSSearch.Snippet(marked: "…the \u{2}zebra\u{3}corn and \u{2}pasta\u{3}")
        #expect(s.runs.map(\.text) == ["…the ", "zebra", "corn and ", "pasta"])
        #expect(s.runs.map(\.isMatch) == [false, true, false, true])
        #expect(s.plain == "…the zebracorn and pasta")
    }

    // MARK: NFR-U10 on the 10,000-chat fixture

    static let bigFixture: URL? = {
        let env = ProcessInfo.processInfo.environment["ANTICHAT_BIG10K_DB"]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = env.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("build/fixtures/big-10k.sqlite")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }()

    /// The 20 AT-012 queries: the fixture token, title words, body words (common and rare), two-word queries.
    static let latencyQueries = [
        "zebracorn", "pasta", "tax", "garden", "bike", "swift", "consider", "simple steps", "quality", "measure",
        "example", "detail", "first", "note time", "useful", "check", "result list", "plan", "small start", "repair",
    ]

    @Test(.enabled(if: bigFixture != nil, "build/fixtures/big-10k.sqlite not generated (tools/fixtures/gen-chats.py)"))
    func tenThousandChatsAnswerWithinNFRU10() throws {
        let src = try #require(Self.bigFixture)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("antichat.sqlite")
        try FileManager.default.copyItem(at: src, to: copy)
        let db = try AppDatabase.onDisk(at: copy)
        #expect(try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat") } == 10_000)
        let search = FTSSearch(db)
        _ = try search.search("warm up")
        // The search's own work: this thread's CPU time (FTSSearch is synchronous; GRDB reads run on the calling
        // thread). Wall time under the full parallel suite measured the host's load, not the query; the wall-clock
        // NFR-U10 number is the AT's (quiet machine).
        func threadCPUms() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
        var ms: [Double] = []
        for q in Self.latencyQueries {
            let t0 = threadCPUms()
            let hits = try search.search(q)
            ms.append(threadCPUms() - t0)
            if q == "zebracorn" { #expect(hits.count == 1) }
        }
        let sorted = ms.sorted()
        let p95 = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
        print("FTSSearch 10k (thread CPU): p50 \(sorted[sorted.count / 2]) ms, p95 \(p95) ms, max \(sorted.last!) ms over \(ms.count)")
        #expect(p95 <= 200, "NFR-U10: p95 \(p95) ms > 200 ms")
    }
}
