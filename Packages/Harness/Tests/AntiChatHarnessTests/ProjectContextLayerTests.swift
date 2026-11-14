// M8.T05 AT-245 unit leg (R-245 AC1/AC2) through the real TurnController with the ScriptedEngine: a project under
// 30 % of the context sends its files whole in the stable layer (`=== name (pages 1–n) ===`, `[p.k]` markers); a
// larger one sends this turn's top passages on the volatile line (`[source n] file p.k: …`, never in the stable
// prefix or the history) and the reply's provenance numbers them; `[n]` resolve only to those sources.
//   make test-unit FILTER=ProjectContextLayerTests
import AntiChatEngineProtocol
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct ProjectContextLayerTests {
    struct Rig {
        let dir: URL
        let db: AppDatabase
        let project: Project
        let chatID: String
        var media: URL { dir.appendingPathComponent("Media") }
    }

    func rig() throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pcl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        let db = try AppDatabase.onDisk(at: dir.appendingPathComponent("antichat.sqlite"))
        let p = try ProjectStore(database: db).create(name: "Studio")
        let chat = try ChatRepository(db).create(projectID: p.id).id
        return Rig(dir: dir, db: db, project: p, chatID: chat)
    }

    func send(_ r: Rig, _ text: String, window: Int? = nil) async throws -> (TurnController, ChatRequest, String) {
        let c = TurnController(chatID: r.chatID, database: r.db,
                               engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"ok [1]","delayMs":1}"#)),
                               contextPolicy: ContextPolicy(windowOverride: window)) { .scripted("inline") }
        await c.setProjectMediaRoot(r.media)
        let log = UpdateLog(c)
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: text, parentID: nil), assistantID: a)
        _ = try await log.waitFinished(a, timeout: .seconds(30))
        return (c, try #require(await c.lastRequest), a)
    }

    @Test func smallProjectGoesWholeIntoTheStableLayer() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        let f = r.dir.appendingPathComponent("src/kiln-notes.md")
        try Data("# Kiln\n\nThe large kiln is called Bertha.".utf8).write(to: f)
        _ = try await ProjectFileIndexer(database: r.db, mediaRoot: r.media, embedder: nil).add([f], to: r.project.id)
        let (c, req, _) = try await send(r, "What is the large kiln called?")
        let ctx = try #require(await c.lastProjectContext)
        #expect(ctx.mode == .whole && ctx.sources.isEmpty)
        let prompt = try #require(await c.lastPrompt)
        #expect(prompt.stablePrefix.contains("=== kiln-notes.md ===") && prompt.stablePrefix.contains("Bertha"))
        let ids = prompt.manifest.sections.map(\.id)
        #expect(ids.contains(PromptLayerID.projectFiles))
        #expect(!(req.turnContext ?? "").contains("[source"))
    }

    @Test func largeProjectRetrievesPassagesPerTurn() async throws {
        let r = try rig()
        defer { try? FileManager.default.removeItem(at: r.dir) }
        var urls: [URL] = []
        for i in 0..<6 {
            let u = r.dir.appendingPathComponent("src/report-\(i).md")
            let filler = (0..<120).map { "Line \($0) of report \(i) about pallet rotation and the canteen budget." }.joined(separator: "\n")
            let fact = i == 4 ? "\nThe Halden warehouse fire inspection is booked under permit HAF-4471.\n" : ""
            try Data("# Report \(i)\n\n\(filler)\(fact)".utf8).write(to: u)
            urls.append(u)
        }
        _ = try await ProjectFileIndexer(database: r.db, mediaRoot: r.media, embedder: nil).add(urls, to: r.project.id)
        // 4,096-token window → budget 1,228; six files of ≈ 1,500 tokens each go to retrieval.
        let (c, req, assistant) = try await send(r, "Which permit is the Halden warehouse fire inspection booked under?", window: 4096)
        let ctx = try #require(await c.lastProjectContext)
        #expect(ctx.mode == .retrieval)
        let turn = try #require(req.turnContext)
        #expect(turn.contains("[source 1] report-4.md") && turn.contains("HAF-4471"))
        #expect(turn.contains(ProjectContextLayer.citeInstruction))
        let prompt = try #require(await c.lastPrompt)
        #expect(!prompt.stablePrefix.contains("HAF-4471"))  // volatile only
        #expect(!req.flattenedHistory.contains { $0.content.contains("[source") })
        let prov = try #require(try await r.db.read { try MessageRecord.fetchOne($0, key: assistant)?.provenance })
        #expect(prov.projectSources?.first?.name == "report-4.md" && prov.projectSources?.first?.n == 1)
    }

    @Test func blocksRender() {
        let w = ProjectContextLayer.wholeBlock([.init(name: "a.pdf", pages: 3, text: "[p.1]\nx\n[p.2]\ny")])
        #expect(w.hasPrefix(ProjectContextLayer.wholeHeading) && w.contains("=== a.pdf (pages 1–3) ===\n[p.1]"))
        #expect(ProjectContextLayer.wholeBlock([.init(name: "b.md", pages: nil, text: String(repeating: "z", count: 100))], maxChars: 10)
            .hasSuffix(ProjectContextLayer.truncatedNote))
        #expect(ProjectContextLayer.wholeBlock([]) == "")
        let hits = [ProjectSourceHit(chunkID: 1, fileID: "f1", fileName: "a.pdf", page: "4", text: "alpha", semantic: false),
                    ProjectSourceHit(chunkID: 2, fileID: "f2", fileName: "s.xlsx", page: "Assets", text: "beta", semantic: false)]
        let (text, sources) = ProjectContextLayer.retrievalBlock(hits)
        #expect(text.contains("[source 1] a.pdf p.4: alpha") && text.contains("[source 2] s.xlsx (Assets): beta"))
        #expect(sources.map(\.n) == [1, 2] && sources[1].page == "Assets")
    }
}
