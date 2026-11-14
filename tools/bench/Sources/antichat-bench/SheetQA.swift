// `antichat-bench sheet-qa` (M6.T08 step 7; AT-272 checks 3a/3b, R-272 AC3): for each sheet-qa-50 item a real turn as
// the app runs it — AttachmentIntake → TurnController (SheetSessions loads the sheet into the chat's DuckDB, the
// prompt carries the profile block, the step offers query_data) → the real chat model over XPC → the tool loop.
// Scored: a number in the answer equal to the gold (relative tolerance 1e-6; golds are rounded as the question asks)
// or the gold text contained (case-insensitive). Network (3b): NetworkGate events + `lsof -i` sampled every 2 s on
// this process and the helper → `network.json` next to the output.
//
//   antichat-bench sheet-qa --fixture fixtures/docs/office/sheet-qa-50.jsonl --tier T1 --out <json> [--model chat-9b-q4]
//                           [--limit N] [--max-tokens 1024]
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation

enum SheetQA {
    struct Item: Decodable {
        var id: String; var files: [String]; var question: String; var kind: String; var answer: Answer
        enum Answer: Decodable {
            case number(Double), text(String)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0; private var hosts: [String] = []
        func add(_ h: String) { lock.lock(); n += 1; hosts.append(h); lock.unlock() }
        var snapshot: (Int, [String]) { lock.lock(); defer { lock.unlock() }; return (n, hosts) }
    }

    static func numbers(_ s: String) -> [Double] {
        s.replacingOccurrences(of: ",", with: "").matches(of: /-?\d+(?:\.\d+)?/).compactMap { Double($0.output) }
    }

    static func score(_ answer: String, _ gold: Item.Answer) -> Bool {
        switch gold {
        case .number(let g): numbers(answer).contains { abs($0 - g) <= max(1e-6 * abs(g), 1e-9) }
        case .text(let t): answer.lowercased().contains(t.lowercased())
        }
    }

    /// Open internet sockets of `pids` (`lsof -i -n -P`), one line each.
    static func sockets(_ pids: [Int32]) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-i", "-n", "-P", "-p", pids.map(String.init).joined(separator: ",")]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return ["lsof failed"] }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return out.split(separator: "\n").dropFirst().map(String.init)
    }

    static func run(_ a: BenchArgs) async throws {
        guard let fixture = a["fixture"] else { throw BenchError("--fixture required") }
        let tierName = a["tier"] ?? "T1"
        let key = a["model"] ?? "chat-9b-q4"
        let root = URL(fileURLWithPath: fixture).deletingLastPathComponent()
        let items = try String(contentsOfFile: fixture, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }.prefix(a.int("limit", 1000))
        let cap = tierName == "T2" ? "T2-24" : tierName
        let tier: DeviceTier = DeviceTier(rawValue: tierName) ?? .t1
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench-sheetqa")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let events = Counter()
        let obs = NetworkGate.addObserver { e in events.add(e.host) }
        defer { NetworkGate.removeObserver(obs) }
        let pids = [ProcessInfo.processInfo.processIdentifier, ack.helperPID]
        let sampler = Task { () -> [String] in
            var seen: [String] = []
            while !Task.isCancelled {
                seen += sockets(pids)
                try? await Task.sleep(for: .seconds(2))
            }
            return seen
        }
        say("helper pid=\(ack.helperPID) model=\(key) tier=\(tierName) items=\(items.count)")
        var rows: [[String: Any]] = []
        var correct = 0
        let start = ContinuousClock.now
        for (i, it) in items.enumerated() {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("sheetqa-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            let db = try AppDatabase.inMemory()
            let intake = AttachmentIntake(database: db, mediaRoot: work.appendingPathComponent("Media"), incognito: false)
            var ids: [String] = []
            for f in it.files {
                let item = await intake.ingest(AttachmentIntake.admit([root.appendingPathComponent(f)]).items[0])
                guard let id = item.attachmentID else { throw BenchError("intake failed for \(f): \(item.state)") }
                ids.append(id)
            }
            let registry = ToolRegistry([SheetTools.queryData()])
            let rt = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(tier),
                                 selection: .standard, tier: { tier })
            let chat = StorageID.make()
            defer { SheetSessions.shared.close(chatID: chat) }
            let c = TurnController(chatID: chat, database: db, engine: client,
                                   sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: a.int("max-tokens", 1024), seed: 7),
                                   tools: rt) { slot }
            let aid = StorageID.make()
            let t = ContinuousClock.now
            let done = Task { () -> TurnResult? in
                for await u in c.updates { if u.assistantID == aid, case .finished(let res) = u.kind { return res } }
                return nil
            }
            await c.start(.send(userID: StorageID.make(), text: it.question, parentID: nil, attachmentIDs: ids), assistantID: aid)
            let res = await done.value
            let answer = (res?.text ?? "").replacingOccurrences(of: #"<think>[\s\S]*?</think>"#, with: "", options: .regularExpression)
            let acts = ToolActivity.activities(in: (try? MessageRepository(db).parts(of: aid)) ?? [])
            let hit = score(answer, it.answer)
            if hit { correct += 1 }
            let gold: Any = { switch it.answer { case .number(let n): n; case .text(let s): s } }()
            rows.append(["id": it.id, "question": it.question, "gold": gold, "answer": answer, "correct": hit,
                         "queries": acts.filter { $0.tool == QueryDataTool.name }.map { ["sql": $0.argumentsJSON, "state": $0.state.rawValue] },
                         "status": res.map { "\($0.status)" } ?? "none", "error": res?.errorCode ?? "",
                         "secs": Stats.secs(ContinuousClock.now - t)])
            say("\(i + 1)/\(items.count) \(hit ? "ok  " : "MISS") \(it.id) queries=\(acts.count) gold=\(gold) → \(answer.prefix(90).replacingOccurrences(of: "\n", with: " "))")
        }
        sampler.cancel()
        let socketLines = await sampler.value
        let (n, hosts) = events.snapshot
        let accuracy = Double(correct) / Double(max(1, items.count))
        let out: [String: Any] = [
            "cmd": "sheet-qa", "tier": tierName, "model": key, "items": items.count, "correct": correct, "accuracy": accuracy,
            "seconds": Stats.secs(ContinuousClock.now - start), "date": ISO8601DateFormatter().string(from: Date()),
            "load": Self.loadAvg(), "rows": rows,
        ]
        let path = a["out"] ?? "sheet-qa.json"
        let u = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: u)
        let net: [String: Any] = ["gate_events": n, "gate_hosts": hosts, "lsof_internet_sockets": socketLines,
                                  "outbound_connections": n + socketLines.count, "pids": pids.map(Int.init)]
        try JSONSerialization.data(withJSONObject: net, options: [.prettyPrinted, .sortedKeys])
            .write(to: u.deletingLastPathComponent().appendingPathComponent("network.json"))
        say("accuracy \(accuracy) (\(correct)/\(items.count)); outbound \(n + socketLines.count) → \(path)")
    }

    static func loadAvg() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        _ = getloadavg(&l, 3)
        return l
    }
}
