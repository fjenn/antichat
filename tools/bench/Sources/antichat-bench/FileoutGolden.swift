// `antichat-bench fileout-golden` (M6.T10 step 7 / M6.T11 step 6; AT-273 check 5, AT-275 check 1c): each golden prompt
// runs as a real turn — TurnController with the app's file tools (create_document, create_spreadsheet, export_table,
// create_presentation when registered) → the real chat model over XPC → the tool loop → the renderers — and every
// produced file is copied to `<out>/<id>.<ext>` for `tools/at/office-open-check.sh --matrix`. Prompts that use images get
// attachment rows for their CC0 photos, sent with the message as the app's composer does (`.send(attachmentIDs:)` links
// them to the user message; AT-273 / AT-275 round 60: rows left as drafts never resolved, 13/13 image decks and the
// image documents failed on "no attachment or file with id"); the ids reach the model through the app's own turn context
// (FileOutContext "Pictures attached in this chat"), not through the prompt text. Recorded per prompt: the tool calls
// (states, arguments, results), whether a repair turn was needed, the file, the reply text, seconds; plus child processes
// of this process (0 expected: the writers run in-process) and the load average.
//
//   antichat-bench fileout-golden --set fixtures/prompts/fileout-golden[/<fmt>-30.jsonl] --tier T1 --out <dir>
//                                 [--model chat-9b-q4] [--limit N per file] [--max-tokens 4096] [--ids id1,id2]
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import Darwin
import Foundation
import GRDB

enum FileoutGolden {
    struct Prompt: Decodable { var id: String; var format: String; var prompt: String; var images: [String]? }

    static func childCount() -> Int {
        var pids = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(getpid(), &pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        return max(0, Int(n))
    }

    static func run(_ a: BenchArgs) async throws {
        guard let set = a["set"] else { throw BenchError("--set required") }
        let out = URL(fileURLWithPath: a["out"] ?? "build/at/fileout-golden", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: set, isDirectory: &isDir)
        let files: [URL] = isDir.boolValue
            ? try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: set), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
            : [URL(fileURLWithPath: set)]
        let limit = a.int("limit", 1000)
        var prompts: [Prompt] = []  // filtered by --ids below
        for f in files {
            prompts += try String(contentsOf: f, encoding: .utf8).split(separator: "\n")
                .map { try JSONDecoder().decode(Prompt.self, from: Data($0.utf8)) }.prefix(limit)
        }
        // M9.T05: `--ids csv-06,xlsx-18` re-runs just those prompts (e.g. the ones a full run lost to a stall).
        if let ids = a["ids"].map({ Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }) {
            prompts = prompts.filter { ids.contains($0.id) }
            guard !prompts.isEmpty else { throw BenchError("--ids matched no prompt") }
        }
        let fixtures = URL(fileURLWithPath: a["fixtures"] ?? "fixtures", isDirectory: true)
        let imageMap = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtures
            .appendingPathComponent("docs/golden-out/specs/images.json")))) ?? [:]
        let tierName = a["tier"] ?? "T1"
        let key = a["model"] ?? "chat-9b-q4"
        let cap = tierName == "T2" ? "T2-24" : tierName
        let tier: DeviceTier = DeviceTier(rawValue: tierName) ?? .t1
        let slot = DevSlots.slot(key)
        let client = EngineClient(appBuild: "antichat-bench-fileout")
        defer { client.disconnect() }
        // AT-273 round 65: every request's events with their times → `<out>/events/<id>.json`.
        let tap = EngineTap(client)
        let eventsDir = out.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        let ack = try await client.ensureConnected()
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        say("helper pid=\(ack.helperPID) model=\(key) tier=\(tierName) prompts=\(prompts.count)")
        var rows: [[String: Any]] = []
        var produced = 0, maxChildren = 0
        let start = ContinuousClock.now
        for (i, p) in prompts.enumerated() {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("fileout-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            let db = try AppDatabase.inMemory()
            let chat = try ChatRepository(db).create(title: p.id)
            let store = ArtifactStore(database: db, mediaRoot: work, incognito: false)
            let text = p.prompt
            var ids: [String] = []
            for ref in p.images ?? [] {
                guard let rel = imageMap[ref] else { continue }
                let url = fixtures.appendingPathComponent(rel)
                let blob = FileBlobRecord(sha256: UUID().uuidString, size: 1, path: url.path, origin: .upload)
                let att = AttachmentRecord(messageID: nil, blobID: blob.id, displayName: url.lastPathComponent, uti: "public.jpeg")
                try db.write { d in try blob.insert(d); try att.insert(d) }
                ids.append(att.id)
            }
            let registry = ToolRegistry([FileOutTools.createDocument(store: store), FileOutTools.createSpreadsheet(store: store),
                                         FileOutTools.exportTable(store: store)] + FileoutGoldenExtra.tools(store))
            let rt = ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(tier),
                                 selection: .standard, tier: { tier })
            let c = TurnController(chatID: chat.id, database: db, engine: tap,
                                   sampling: Sampling(temperature: 0.2, topP: 0.9, maxTokens: a.int("max-tokens", 4096), seed: 7),
                                   tools: rt) { slot }
            let aid = StorageID.make()
            let t = ContinuousClock.now
            let done = Task { () -> TurnResult? in
                for await u in c.updates { if u.assistantID == aid, case .finished(let res) = u.kind { return res } }
                return nil
            }
            await c.start(.send(userID: StorageID.make(), text: text, parentID: nil, attachmentIDs: ids), assistantID: aid)
            let res = await done.value
            // M9.T05 (AT-273 xlsx-18): every engine request's tool_choice — after a file-tool repair notice the next step
            // must be forced to that tool (round 62), so a text answer there is visible here.
            let choices = await c.requests.map { $0.toolChoice.map { String(describing: $0) } ?? "nil" }
            let requestLog = tap.drain()
            try? JSONSerialization.data(withJSONObject: ["id": p.id, "load": SheetQA.loadAvg(), "requests": requestLog],
                                        options: [.prettyPrinted, .sortedKeys])
                .write(to: eventsDir.appendingPathComponent("\(p.id).json"))
            maxChildren = max(maxChildren, childCount())
            let acts = ToolActivity.activities(in: (try? MessageRepository(db).parts(of: aid)) ?? []).filter { $0.kind == .tool }
            // The produced file comes from the store (activity ids can repeat across steps, and a loop-limit line is
            // an activity too): the newest artifact version of this chat.
            struct Made { var file: String; var path: String; var format: String }
            let made: Made? = try db.read { d in
                guard let v = try ArtifactVersionRecord.order(Column("created_at").desc).fetchOne(d),
                      let art = try ArtifactRecord.fetchOne(d, key: v.artifactID),
                      let blob = try FileBlobRecord.fetchOne(d, key: v.blobID) else { return nil }
                return Made(file: art.title, path: blob.path, format: art.kind)
            }
            var file = ""
            if let made {
                let dst = out.appendingPathComponent("\(p.id).\((made.file as NSString).pathExtension.lowercased())")
                try? FileManager.default.removeItem(at: dst)
                try FileManager.default.copyItem(at: URL(fileURLWithPath: made.path), to: dst)
                file = dst.lastPathComponent
                produced += 1
            }
            let repaired = acts.contains { $0.state == .failed }
            rows.append(["id": p.id, "format": p.format, "file": file, "calls": acts.map { ["tool": $0.tool, "state": $0.state.rawValue, "args": String($0.argumentsJSON.prefix(4000)),
                                                                                           "detail": String(($0.result ?? "").prefix(1500))] },
                         "reply": String((res?.text ?? "").prefix(800)), "error": res?.errorCode ?? "",
                         "repair_turn": repaired, "right_format": made.map { $0.format == p.format } ?? false,
                         "status": res.map { "\($0.status)" } ?? "none", "secs": Stats.secs(ContinuousClock.now - t),
                         "last_tool_choice": choices.last ?? "no request", "tool_choices": choices, "load": SheetQA.loadAvg()])
            say("\(i + 1)/\(prompts.count) \(made == nil ? "NONE" : "file") \(p.id) calls=\(acts.map { "\($0.tool):\($0.state.rawValue)" }) \(file)")
            for f in acts where f.state == .failed {
                say("    failed: \((f.result ?? "").prefix(400).replacingOccurrences(of: "\n", with: " "))")
                say("    args: \(f.argumentsJSON.prefix(600))")
            }
        }
        let summary: [String: Any] = [
            "cmd": "fileout-golden", "tier": tierName, "model": key, "prompts": prompts.count, "files": produced,
            "child_processes_max": maxChildren, "seconds": Stats.secs(ContinuousClock.now - start),
            "date": ISO8601DateFormatter().string(from: Date()), "load": SheetQA.loadAvg(), "rows": rows,
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("fileout-golden.json"))
        say("files \(produced)/\(prompts.count), child processes max \(maxChildren) → \(out.path)")
    }
}

/// Tools later tasks add to the golden run (M6.T11: create_presentation).
enum FileoutGoldenExtra {
    static func tools(_ store: ArtifactStore) -> [RegisteredTool] { [FileOutTools.createPresentation(store: store)] }
}
