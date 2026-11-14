// `antichat-bench files-pagecite` (M6.T02 step 10; AT-270 check 4b, R-270 AC4): for each pagecite-100 item a real
// turn with the document attached on the excerpt path (the T1 tier fixture of budget-40.expected.json forces it):
// AttachmentIntake → DocumentContextAssembler.plan (CountTokens by the model's tokenizer, DocumentIndexer chunks with
// page refs, hybrid retrieval with the helper's embed model, top-k of the tier) → the user turn as the app builds it
// → chat. Scored "exact page" = a valid (p. N) cited ∈ gold_pages AND the answer contains gold_answer (normalised).
//
//   antichat-bench files-pagecite --fixture fixtures/docs/pagecite-100.jsonl --tier T1 --out <json> [--model chat-9b-q4]
//                                 [--limit N]
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation

enum FilesPagecite {
    struct Item: Decodable { var doc: String; var question: String; var gold_pages: [Int]; var gold_answer: String }

    static func run(_ a: BenchArgs) async throws {
        guard let fixture = a["fixture"] else { throw BenchError("--fixture required") }
        let tier = a["tier"] ?? "T1"
        let key = a["model"] ?? "chat-9b-q4"
        let docsRoot = URL(fileURLWithPath: fixture).deletingLastPathComponent()
        let items = try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }.prefix(a.int("limit", 1000))
        struct TierP: Decodable { var context_tokens: Int; var prefill_tps: Double; var fixed_tokens: Int }
        struct Exp: Decodable { var tiers: [String: TierP] }
        let exp = try JSONDecoder().decode(Exp.self, from: Data(contentsOf: docsRoot.appendingPathComponent("budget-40.expected.json")))
        guard let tp = exp.tiers[tier] else { throw BenchError("--tier \(tier) not in budget-40.expected.json") }
        let cap = tier == "T2" ? "T2-24" : tier
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let embedSlot = DevSlots.slot("embed")
        let embedder: (any Embedder)? = FileManager.default.fileExists(atPath: embedSlot.path)
            ? HelperEmbedder(engine: client, embedSlot: { embedSlot }) : nil
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pagecite-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let db = try AppDatabase.onDisk(at: work.appendingPathComponent("antichat.sqlite"))
        let intake = AttachmentIntake(database: db, mediaRoot: work.appendingPathComponent("Media"), incognito: false)
        let assembler = DocumentContextAssembler(database: db, embedder: embedder, tier: { tier })
        let composer = PromptComposer()
        var rows: [[String: Any]] = []
        var exact = 0
        let start = ContinuousClock.now
        for (i, it) in items.enumerated() {
            let item = await intake.ingest(AttachmentIntake.admit([docsRoot.appendingPathComponent(it.doc)]).items[0])
            guard let att = item.attachmentID else { throw BenchError("intake failed for \(it.doc): \(item.state)") }
            let plan = await assembler.plan(
                attachmentIDs: [att], userText: it.question,
                model: .init(contextTokens: tp.context_tokens, prefillTPS: tp.prefill_tps),
                chat: .init(fixedTokens: tp.fixed_tokens, historyTokens: 0),
                countTokens: { await client.countTokens($0, slot: slot) })
            guard let f = plan.files.first else { throw BenchError("no plan") }
            let blocks = f.excerpts.map { DocumentContextAssembler.excerpt(name: f.name, page: $0.pageRef, text: $0.text) }
                + [DocumentContextAssembler.citeInstruction]
            let content = DocumentContextAssembler.userContent(it.question, documents: blocks)
            let req = composer.compose(PromptInputs(), context: VolatileContext()).request(
                sessionID: UUID(), modelSlot: slot, conversation: [ChatMessage(role: .user, content: content)],
                sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: 160, seed: 7))
            var text = ""
            for try await e in client.chat(req) { if case .textDelta(let s) = e { text += s } }
            let answer = text.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            let retrieved = Set(f.excerpts.compactMap { $0.pageRef.flatMap(Int.init) })
            let cited = answer.matches(of: /\(pp?\.\s?(\d{1,4})/).compactMap { Int($0.output.1) }.filter(retrieved.contains)
            let norm: (String) -> String = { $0.uppercased().filter { $0.isLetter || $0.isNumber } }
            let hit = cited.contains { it.gold_pages.contains($0) } && norm(answer).contains(norm(it.gold_answer))
            if hit { exact += 1 }
            rows.append(["doc": it.doc, "question": it.question, "gold_pages": it.gold_pages, "retrieved": retrieved.sorted(),
                         "cited": cited, "answer": answer, "exact": hit, "mode": f.decision.mode.rawValue,
                         "semantic": f.semantic, "tokens": f.tokens])
            say("\(i + 1)/\(items.count) \(hit ? "ok " : "MISS") \(it.doc) gold \(it.gold_pages) cited \(cited) retrieved \(retrieved.sorted())")
        }
        let out: [String: Any] = [
            "cmd": "files-pagecite", "tier": tier, "model": key, "items": items.count, "exact": exact,
            "exact_page_rate": Double(exact) / Double(max(1, items.count)), "seconds": Stats.secs(ContinuousClock.now - start),
            "embedder": embedder != nil, "date": ISO8601DateFormatter().string(from: Date()), "rows": rows,
        ]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let path = a["out"] ?? a["json"] ?? "pagecite.json"
        let u = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        say("exact_page_rate \(Double(exact) / Double(max(1, items.count))) → \(path)")
    }
}
