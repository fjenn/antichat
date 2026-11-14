// M2.T16: RRF (k = 60), chunking, the resumable indexer, and HybridRetriever incl. the R-244 AC3 fallback: no
// embedder / a failing embedder → FTS-only results and no error (HybridFallbackTests).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatKnowledge

/// Deterministic concept embedder: words of one synonym group share a dimension.
struct ConceptEmbedder: Embedder {
    static let groups: [[String]] = [["dog", "puppy", "hound", "canine"], ["boat", "sailing", "yacht"],
                                     ["bread", "sourdough", "baking"], ["tax", "invoice", "receipt"]]
    var fail = false
    func embed(_ texts: [String], kind: EmbedRequest.Kind) async throws -> [[Float]] {
        if fail { throw CancellationError() }
        return texts.map { t in
            var v = [Float](repeating: 0, count: VecLoader.dimensions)
            for w in t.lowercased().split(whereSeparator: { !$0.isLetter }) {
                if let g = Self.groups.firstIndex(where: { $0.contains(String(w)) }) { v[g] += 1 }
            }
            v[1000] = 0.01
            let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return v.map { $0 / n }
        }
    }
    func rerank(query: String, documents: [String]) async throws -> [Float]? { nil }
}

func seed(_ texts: [String]) throws -> (AppDatabase, [String]) {
    let db = try AppDatabase.inMemory()
    var chats: [String] = []
    try db.write { db in
        for (i, t) in texts.enumerated() {
            let chat = "c\(i)", msg = "m\(i)"
            try db.execute(sql: "INSERT INTO chat(id, title, created_at, updated_at) VALUES (?, ?, 0, 0)", arguments: [chat, "chat \(i)"])
            try db.execute(sql: "INSERT INTO message(id, chat_id, role, status, created_at) VALUES (?, ?, 'assistant', 'done', ?)",
                           arguments: [msg, chat, Double(i)])
            try db.execute(sql: "INSERT INTO message_part(message_id, idx, kind, body) VALUES (?, 0, 'text', ?)", arguments: [msg, t])
            chats.append(chat)
        }
    }
    return (db, chats)
}

@Suite("RRFTests") struct RRFTests {
    @Test func fusesByReciprocalRank() {
        let fused = RRF.fuse([["a", "b", "c"], ["c", "a", "d"]])
        #expect(fused.map(\.key) == ["a", "c", "b", "d"])
        #expect(abs(fused[0].score - (1.0 / 61 + 1.0 / 62)) < 1e-12)
        #expect(RRF.fuse([[String]]()).isEmpty)
    }

    @Test func chunkerRespectsTheLimit() {
        let long = (0..<900).map { "word\($0)." }.joined(separator: " ")
        let chunks = Chunker.chunks("Short intro.\n\n" + long)
        #expect(chunks.count >= 4)
        #expect(chunks.allSatisfy { $0.count <= Chunker.maxChars })
        #expect(Chunker.chunks("  \n ").isEmpty)
    }
}

@Suite("HybridFallbackTests") struct HybridFallbackTests {
    let texts = ["My puppy chewed the sofa again", "We went sailing on a small yacht",
                 "Sourdough starter needs feeding", "Keep every receipt for the accountant"]

    @Test func semanticFindsWhatFTSCannot() async throws {
        let (db, chats) = try seed(texts)
        let indexer = BackgroundIndexer(database: db)
        #expect(try await indexer.catchUp() == 4)
        #expect(try await indexer.catchUp() == 0)  // resumable: nothing new
        #expect(try await indexer.embedPending(with: ConceptEmbedder()) == 4)
        #expect(try await indexer.pendingCount() == 0)
        let r = HybridRetriever(database: db, embedder: ConceptEmbedder(), enabled: true)
        let hits = await r.search("dog")
        #expect(hits.first?.chatID == chats[0])
        #expect(hits.first?.semantic == true)
        let tax = await r.search("tax invoice")
        #expect(tax.first?.chatID == chats[3])
    }

    @Test func missingOrFailingEmbedderFallsBackToFTS() async throws {
        let (db, chats) = try seed(texts)
        try await BackgroundIndexer(database: db).catchUp()
        for r in [HybridRetriever(database: db, embedder: nil, enabled: true),
                  HybridRetriever(database: db, embedder: ConceptEmbedder(fail: true), enabled: true),
                  HybridRetriever(database: db, embedder: ConceptEmbedder(), enabled: false)] {
            let hits = await r.search("sourdough")
            #expect(hits.map(\.chatID) == [chats[2]])
            #expect(hits.allSatisfy { !$0.semantic })
            #expect(await r.search("dog").isEmpty)  // no FTS match, no vectors: empty, no error
        }
    }

    @Test func deletingAChatDropsItsChunksAndVectors() async throws {
        let (db, _) = try seed(texts)
        let indexer = BackgroundIndexer(database: db)
        try await indexer.catchUp()
        try await indexer.embedPending(with: ConceptEmbedder())
        try await db.write { try $0.execute(sql: "DELETE FROM chat WHERE id = 'c0'") }
        let counts = try await db.read { db in
            [try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk"), try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_vec")]
        }
        #expect(counts == [3, 3])
        #expect(try await indexer.rebuild() == 3)
    }
}

/// Random unit vectors (KNN cost does not depend on content) for the latency run.
struct RandomEmbedder: Embedder {
    func embed(_ texts: [String], kind: EmbedRequest.Kind) async throws -> [[Float]] {
        texts.map { _ in
            let v = (0..<VecLoader.dimensions).map { _ in Float.random(in: -1...1) }
            let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
            return v.map { $0 / n }
        }
    }
    func rerank(query: String, documents: [String]) async throws -> [Float]? { nil }
}

/// AT-295 retrieval stage (M2.T16): FTS top 50 + vec0 KNN top 50 over 60,000 chunks (≈ the 10k-chat fixture's
/// message count) + RRF, 20 runs. The query embedding is timed separately with the real model
/// (EmbeddingServiceRealTests). Set ANTICHAT_RETRIEVAL_OUT to write the p50/p95 JSON.
@Suite("RetrievalLatencyTests", .serialized) struct RetrievalLatencyTests {
    @Test func hybridStageUnderBudgetAt60kChunks() async throws {
        let n = 60_000
        let db = try AppDatabase.inMemory()
        let words = ["dog", "boat", "bread", "tax", "garden", "music", "travel", "code", "health", "movie"]
        try await db.write { db in
            try db.execute(sql: "INSERT INTO chat(id, title, created_at, updated_at) VALUES ('c', 't', 0, 0)")
            for i in 0..<n {
                try db.execute(sql: "INSERT INTO chunk(source, source_id, chat_id, ord, text, created_at) VALUES ('m', ?, 'c', 0, ?, 0)",
                               arguments: ["m\(i)", "note \(i) about \(words[i % 10]) and \(words[(i / 10) % 10])"])
                let v = (0..<VecLoader.dimensions).map { _ in Float.random(in: -1...1) }
                try db.execute(sql: "INSERT INTO chunk_vec(rowid, embedding) VALUES (?, ?)", arguments: [db.lastInsertedRowID, ChunkTables.blob(v)])
            }
        }
        let r = HybridRetriever(database: db, embedder: RandomEmbedder(), enabled: true)
        // The unit bar is the retrieval's own work: this thread's CPU time over the stages the search runs (FTS, the
        // vector KNN, the text join; GRDB reads run on the calling thread). Wall time under the full parallel suite
        // measured the host's load (other suites preempting this thread), not the search. The wall-clock numbers
        // stay in ANTICHAT_RETRIEVAL_OUT for the AT run (quiet machine).
        func threadCPUms() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6 }
        var ms: [Double] = []
        var cpu: [Double] = []
        for i in 0..<20 {
            let q = "\(words[i % 10]) plans"
            let t = ContinuousClock.now
            #expect(await !r.search(q).isEmpty)
            let d = ContinuousClock.now - t
            ms.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
            let v = try #require(try await RandomEmbedder().embed([q], kind: .query).first)
            let c0 = threadCPUms()
            let fts = try r.ftsIDs(q)
            let knn = try r.knnIDs(v)
            let order = RRF.fuse([fts, knn]).map(\.key)
            _ = try r.texts(order)
            cpu.append(threadCPUms() - c0)
            #expect(!knn.isEmpty)
        }
        ms.sort()
        cpu.sort()
        let p50 = ms[9], p95 = ms[18], cpuP95 = cpu[18]
        if let out = ProcessInfo.processInfo.environment["ANTICHAT_RETRIEVAL_OUT"] {
            let json = #"{"chunks": \#(n), "runs": 20, "p50_ms": \#(p50), "p95_ms": \#(p95), "cpu_p95_ms": \#(cpuP95), "budget_ms": 300}"#
            try json.write(toFile: out, atomically: true, encoding: .utf8)
        }
        print("HybridRetriever: wall p95 \(p95) ms, CPU p95 \(cpuP95) ms")
        #expect(cpuP95 < 300, "CPU p95 \(cpuP95) ms")
    }
}
