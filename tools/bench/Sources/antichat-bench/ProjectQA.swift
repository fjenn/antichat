// `antichat-bench project-qa` (M8.T05 step 4; AT-245 AC3, R-245): the 50-question project set through the app's own
// path — qa-50/docs linked as a project folder (ProjectFileIndexer: extraction, chunks with page refs, vectors with
// the helper's `embed`), one fresh project chat per question, TurnController (ProjectContextPlanner →
// ProjectRetriever → ProjectContextLayer) → the real chat model over XPC. Correct = `answer_regex` matches the reply
// (case-insensitive) AND one `[n]` it cites resolves (provenance project_sources) to the question's file and page
// (±0; ±1 with page_tolerance 1; page null = the file). Then small/ (3 docs) must plan `.whole` and answer 10
// questions (regex only: whole mode has no numbered passages).
//
//   antichat-bench project-qa --fixture fixtures/projects/qa-50 --tier T1 --out build/at/AT-245/<date>.json
//                             [--model chat-9b-q4] [--limit N] [--no-embed]
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import Foundation

enum ProjectQA {
    struct Item: Decodable {
        var q: String
        var answer_regex: String
        var file: String
        var page: Page?
        var page_tolerance: Int?
        enum Page: Decodable, Equatable {
            case number(Int), label(String)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let i = try? c.decode(Int.self) { self = .number(i) } else { self = .label(try c.decode(String.self)) }
            }
            var text: String { switch self { case .number(let n): "\(n)"; case .label(let s): s } }
        }
    }

    static func items(_ url: URL) throws -> [Item] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
    }

    static func strip(_ s: String) -> String {
        s.replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
    }

    static func matches(_ rx: String, _ text: String) -> Bool {
        guard let r = try? NSRegularExpression(pattern: rx, options: [.caseInsensitive]) else { return false }
        return r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The `[n]` / `[source n]` / `[1, 2]` numbers a reply cites.
    static func cited(_ text: String) -> [Int] {
        let rx = try! NSRegularExpression(pattern: #"\[(?:source\s*)?(\d{1,2}(?:\s*,\s*\d{1,2})*)\]"#, options: [.caseInsensitive])
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).flatMap { m in
            ns.substring(with: m.range(at: 1)).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    static func citationOK(_ it: Item, cited: [Int], sources: [MessageProvenance.ProjectSource]) -> Bool {
        let tol = it.page_tolerance ?? 0
        return cited.compactMap { n in sources.first { $0.n == n } }.contains { s in
            guard s.name == it.file else { return false }
            switch it.page {
            case nil: return true
            case .label(let l)?: return s.page == l
            case .number(let p)?: return s.page.flatMap(Int.init).map { abs($0 - p) <= tol } ?? false
            }
        }
    }

    static func run(_ a: BenchArgs) async throws {
        guard let fixture = a["fixture"] else { throw BenchError("--fixture required") }
        let root = URL(fileURLWithPath: fixture, isDirectory: true)
        let tierName = a["tier"] ?? "T1"
        let key = a["model"] ?? "chat-9b-q4"
        let cap = tierName == "T2" ? "T2-24" : tierName
        let slot = DevSlots.slot(key)
        let window = a.int("context", slot.contextTokens ?? 16_384)
        let client = EngineClient(appBuild: "antichat-bench-projectqa")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let embedSlot = DevSlots.slot("embed")
        let embedder: (any Embedder)? = a["no-embed"] != nil || !FileManager.default.fileExists(atPath: embedSlot.path)
            ? nil : HelperEmbedder(engine: client, embedSlot: { embedSlot })
        say("helper pid=\(ack.helperPID) model=\(key) tier=\(tierName) context=\(window) embedder=\(embedder != nil) load=\(SheetQA.loadAvg())")

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("projectqa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let db = try AppDatabase.onDisk(at: work.appendingPathComponent("antichat.sqlite"))
        let media = work.appendingPathComponent("Media")
        let store = ProjectStore(database: db)
        let indexer = ProjectFileIndexer(database: db, mediaRoot: media, embedder: embedder)

        func ask(_ project: Project, _ q: String) async throws -> (TurnResult?, ProjectContextLayer.Turn?, [MessageProvenance.ProjectSource], Double) {
            let chat = try ChatRepository(db).create(projectID: project.id).id
            let c = TurnController(chatID: chat, database: db, engine: client,
                                   sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: a.int("max-tokens", 1024), seed: 7),
                                   contextPolicy: ContextPolicy(windowOverride: window)) { slot }
            await c.setProjectMediaRoot(media)
            await c.setDocumentEmbedder(embedder)
            let aid = StorageID.make()
            let t = ContinuousClock.now
            let done = Task { () -> TurnResult? in
                for await u in c.updates { if u.assistantID == aid, case .finished(let res) = u.kind { return res } }
                return nil
            }
            await c.start(.send(userID: StorageID.make(), text: q, parentID: nil), assistantID: aid)
            let res = await done.value
            let prov = try db.read { try MessageRecord.fetchOne($0, key: aid)?.provenance }
            return (res, await c.lastProjectContext, prov?.projectSources ?? [], Stats.secs(ContinuousClock.now - t))
        }

        // qa-50: the 120 documents as a linked folder (no copy limit; R-064 linked folders).
        let big = try store.create(name: "qa-50")
        let t0 = ContinuousClock.now
        let scan = try await indexer.link(root.appendingPathComponent("docs", isDirectory: true), to: big.id)
        let indexSecs = Stats.secs(ContinuousClock.now - t0)
        let files = try store.files(big.id)
        let vectors = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chunk_vec") ?? 0 }
        let chunks = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chunk WHERE source = 'project_file'") ?? 0 }
        say("indexed \(scan.indexed) files (\(files.filter { $0.indexState == .ready }.count) ready, \(chunks) chunks, \(vectors) vectors) in \(indexSecs) s")

        var rows: [[String: Any]] = []
        var correct = 0, answerOnly = 0, citeOnly = 0
        var modes = Set<String>()
        let qa = try items(root.appendingPathComponent("questions.jsonl")).prefix(a.int("limit", 50))
        for (i, it) in qa.enumerated() {
            let (res, ctx, sources, secs) = try await ask(big, it.q)
            let reply = strip(res?.text ?? "")
            let ans = matches(it.answer_regex, reply)
            let c = cited(reply)
            let citeOK = citationOK(it, cited: c, sources: sources)
            let retrievedGold = sources.contains { s in s.name == it.file && (it.page.map { $0.text == s.page } ?? true) }
            if ans && citeOK { correct += 1 }
            if ans { answerOnly += 1 }
            if citeOK { citeOnly += 1 }
            modes.insert(ctx?.mode.rawValue ?? "none")
            rows.append(["q": it.q, "file": it.file, "page": it.page?.text ?? NSNull(), "reply": String(reply.prefix(600)),
                         "answer_ok": ans, "citation_ok": citeOK, "correct": ans && citeOK, "cited": c,
                         "gold_retrieved": retrievedGold, "mode": ctx?.mode.rawValue ?? "none",
                         "sources": sources.map { ["n": $0.n, "file": $0.name, "page": $0.page ?? NSNull()] as [String: Any] },
                         "status": res.map { "\($0.status)" } ?? "none", "secs": secs])
            say("\(i + 1)/\(qa.count) \(ans && citeOK ? "ok  " : "MISS") ans=\(ans) cite=\(citeOK) retrieved=\(retrievedGold) \(it.file) p=\(it.page?.text ?? "-") cited=\(c)")
        }

        // small/: whole mode, 10 questions.
        let small = try store.create(name: "small")
        _ = try await indexer.link(root.appendingPathComponent("small", isDirectory: true), to: small.id)
        var smallRows: [[String: Any]] = []
        var smallCorrect = 0
        var smallWhole = true
        for it in try items(root.appendingPathComponent("questions-small.jsonl")) {
            let (res, ctx, _, secs) = try await ask(small, it.q)
            let reply = strip(res?.text ?? "")
            let ok = matches(it.answer_regex, reply)
            if ok { smallCorrect += 1 }
            if ctx?.mode != .whole { smallWhole = false }
            smallRows.append(["q": it.q, "reply": String(reply.prefix(400)), "correct": ok, "mode": ctx?.mode.rawValue ?? "none", "secs": secs])
            say("small \(ok ? "ok  " : "MISS") mode=\(ctx?.mode.rawValue ?? "none") \(it.q)")
        }

        let out: [String: Any] = [
            "cmd": "project-qa", "at": "AT-245", "tier": tierName, "model": key, "context": window, "embedder": embedder != nil,
            "rerank": false, "index_seconds": indexSecs, "files": files.count, "chunks": chunks, "vectors": vectors,
            "qa50_questions": qa.count, "qa50_correct_with_citation": correct, "qa50_answer_ok": answerOnly,
            "qa50_citation_ok": citeOnly, "qa50_modes": Array(modes).sorted(),
            "small_whole_mode": smallWhole, "small_correct": smallCorrect, "small_questions": smallRows.count,
            "pass": correct >= 40 && smallWhole && smallCorrect >= 8 && modes == ["retrieval"],
            "date": ISO8601DateFormatter().string(from: Date()), "load": SheetQA.loadAvg(), "rows": rows, "small_rows": smallRows,
        ]
        let path = a["out"] ?? "build/at/AT-245/project-qa.json"
        let u = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: u)
        say("AT AT-245 \(out["pass"] as? Bool == true ? "PASS" : "FAIL") qa50_correct_with_citation=\(correct)/\(qa.count) small_whole_mode=\(smallWhole) small_correct=\(smallCorrect)/\(smallRows.count) → \(path)")
    }
}
