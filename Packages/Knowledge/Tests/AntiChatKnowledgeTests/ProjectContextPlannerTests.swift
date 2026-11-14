// M8.T05 AT-245 unit leg (R-245 AC1/AC2): the 30 % switch at its boundary for the default context of every tier's
// default chat model (catalog/assignments.yaml: T0 8,192; T1 16,384; T2 32,768; T3 65,536; T4 131,072), the ready-files-only total,
// the ff.projectRetrieval rollback, and the retriever: project-scoped FTS (+ RRF), page refs, top-k and the 25 % cap.
//   make test-unit FILTER=ProjectContextPlannerTests
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatKnowledge

@Suite(.serialized) struct ProjectContextPlannerTests {
    /// Default chat contexts per tier (catalog/assignments.yaml S1 cells, normal mode).
    static let tierContexts: [(String, Int)] = [("T0", 8192), ("T1", 16_384), ("T2-24", 32_768), ("T3-48", 65_536), ("T4-96", 131_072)]

    @Test func boundaryIsThirtyPercentPerTierContext() {
        #expect(ProjectContextPlanner.budget(contextLength: 16_384) == 4915)  // M8.md: chat-9b-q4 16K → 4,915
        for (tier, ctx) in Self.tierContexts {
            let b = ProjectContextPlanner.budget(contextLength: ctx)
            #expect(b == Int(Double(ctx) * 0.3), "\(tier)")
            #expect(ProjectContextPlanner.mode(totalTokens: b, contextLength: ctx) == .whole, "\(tier) at 30 %")
            #expect(ProjectContextPlanner.mode(totalTokens: b + 1, contextLength: ctx) == .retrieval, "\(tier) at 30 % + 1")
            #expect(ProjectContextPlanner.mode(totalTokens: b + 1, contextLength: ctx, retrievalEnabled: false) == .whole)
        }
        #expect(ProjectContextPlanner.mode(totalTokens: 0, contextLength: 16_384) == .none)
    }

    @Test func catalogContextsMatch() throws {
        // The table above is the catalog's: fail if assignments.yaml moves (the generator asserts the same for T1).
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let yaml = try String(contentsOf: root.appendingPathComponent("catalog/assignments.yaml"), encoding: .utf8)
        for (tier, ctx) in Self.tierContexts {
            guard let block = yaml.components(separatedBy: "\n  \(tier):\n").dropFirst().first else {
                Issue.record("no \(tier) cell"); continue
            }
            let line = block.split(separator: "\n").first { $0.contains("chat: {normal:") }.map(String.init) ?? ""
            #expect(line.contains("ctx: \(ctx),"), "\(tier): \(line)")
        }
    }

    func rig() throws -> (URL, AppDatabase, Project) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        return (dir, db, try ProjectStore(database: db).create(name: "Plan"))
    }

    func insertFile(_ db: AppDatabase, project: String, name: String, tokens: Int, state: ProjectIndexState = .ready,
                    chunks: [(String, String?)] = []) throws -> String {
        let f = ProjectFile(id: StorageID.make(), projectID: project, displayName: name, size: 10, origin: .copied,
                            textTokens: tokens, indexState: state, progress: 1, createdAt: Date())
        try db.write { db in
            try f.insert(db)
            for (i, (text, page)) in chunks.enumerated() {
                try db.execute(sql: "INSERT INTO chunk(source, source_id, chat_id, ord, text, created_at, page_ref) VALUES (?, ?, NULL, ?, ?, 0, ?)",
                               arguments: [ProjectFile.chunkSource, f.id, i, text, page])
            }
        }
        return f.id
    }

    @Test func planCountsReadyFilesOnly() throws {
        let (dir, db, p) = try rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try insertFile(db, project: p.id, name: "a.md", tokens: 4000)
        _ = try insertFile(db, project: p.id, name: "b.md", tokens: 915)
        _ = try insertFile(db, project: p.id, name: "c.md", tokens: 9000, state: .indexing)
        var plan = try db.read { try ProjectContextPlanner.plan(projectID: p.id, contextLength: 16_384, db: $0, retrievalEnabled: true) }
        #expect(plan.totalTokens == 4915 && plan.mode == .whole && plan.files.count == 2)
        try db.write { try $0.execute(sql: "UPDATE project_file SET index_state = 'ready' WHERE display_name = 'c.md'") }
        plan = try db.read { try ProjectContextPlanner.plan(projectID: p.id, contextLength: 16_384, db: $0, retrievalEnabled: true) }
        #expect(plan.mode == .retrieval && !plan.truncated)  // re-evaluated: the file finished indexing
        plan = try db.read { try ProjectContextPlanner.plan(projectID: p.id, contextLength: 16_384, db: $0, retrievalEnabled: false) }
        #expect(plan.mode == .whole && plan.truncated)  // rollback: whole, cut with a notice
        let chat = ChatRecord(id: StorageID.make(), mode: .normal)
        try db.write { db in
            try chat.insert(db)
            try db.execute(sql: "UPDATE chat SET project_id = ? WHERE id = ?", arguments: [p.id, chat.id])
        }
        #expect(try db.read { try ProjectContextPlanner.plan(chatID: chat.id, contextLength: 16_384, db: $0, retrievalEnabled: true) }?.projectID == p.id)
        #expect(try db.read { try ProjectContextPlanner.plan(chatID: "none", contextLength: 16_384, db: $0) } == nil)
    }

    @Test func retrieverIsProjectScopedWithPagesAndCap() async throws {
        let (dir, db, p) = try rig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = try ProjectStore(database: db).create(name: "Other")
        let a = try insertFile(db, project: p.id, name: "report.pdf", tokens: 9000, chunks: [
            ("The Halden warehouse fire inspection is booked under permit HAF-4471.", "7"),
            ("Pallet rotation was discussed at length.", "8"),
        ])
        _ = try insertFile(db, project: other.id, name: "elsewhere.md", tokens: 9000, chunks: [
            ("The Halden warehouse fire inspection is booked under permit HAF-9999.", "Section 1"),
        ])
        let r = ProjectRetriever(database: db, embedder: nil)
        let hits = await r.search("Which permit for the Halden warehouse fire inspection?", projectID: p.id, tier: "T1", contextLength: 16_384)
        #expect(hits.first?.fileID == a && hits.first?.page == "7" && hits.first?.text.contains("HAF-4471") == true)
        #expect(!hits.contains { $0.text.contains("9999") })  // the other project's file never leaks in
        #expect(hits.count <= ProjectRetriever.topK)
        // 25 % cap: with a tiny context only what fits is kept (at least nothing over the cap).
        let capped = await r.search("Halden pallet rotation", projectID: p.id, tier: "T1", contextLength: 40,
                                    countTokens: { _ in 9 })
        #expect(capped.count == 1)
        #expect(ProjectRetriever.query(lastUser: "and in March?", previousUser: "Rent at Halden") == "Rent at Halden\nand in March?")
        #expect(ProjectRetriever.tierClass("T2-24") == "T2")
        let gold = "Kestrel Valley Co-operative — Yarrow report. The backup generator at the Fenwick depot was last serviced by Orchid."
        let decoy = "Kestrel Valley Co-operative — Fenwick report. The backup generator at the Yarrow depot was last serviced by Pellham."
        let q = "Which company last serviced the backup generator at the Fenwick depot?"
        #expect(ProjectRetriever.sentenceScore(gold, query: q, anchors: ["Fenwick"]) > ProjectRetriever.sentenceScore(decoy, query: q, anchors: ["Fenwick"]))
        #expect(ProjectRetriever.anchors("Who is the custodian of asset KV-64652? Which site at Halden.") == ["KV-64652", "Halden"])
    }
}
