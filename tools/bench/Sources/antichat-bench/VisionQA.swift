// `antichat-bench vision-qa` (M6.T05 step 5; AT-021 check 2, R-021 AC2): one turn per item of fixtures/images/ocr
// (image + question), the image prepared as the app prepares it (ImageInputPreparer: long side ≤ 1024, PNG in the
// transfer dir, path over XPC), scored with the item's normaliser: `exact` / `contains` = the answer appears in the
// reply (case-insensitive), `number` = the number appears (separators ignored). Pass: accuracy ≥ 0.90 on the T1
// default model at the T1 cap; T0 and Evil runs are information.
//
//   antichat-bench vision-qa --fixture fixtures/images/ocr --tier T1 --out <json> [--model chat-9b-q4+vision]
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import Foundation

enum VisionQA {
    struct Item: Decodable { var file: String; var question: String; var answer: String; var normaliser: String }

    static func score(_ text: String, _ item: Item) -> Bool {
        let t = text.lowercased()
        switch item.normaliser {
        case "number":
            let digits = { (s: String) in s.filter { $0.isNumber || $0 == "." } }
            let want = digits(item.answer)
            let tokens = t.replacingOccurrences(of: ",", with: "").split { !($0.isNumber || $0 == ".") }.map(String.init)
            return tokens.contains { $0 == want || $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == want }
        default:
            return t.contains(item.answer.lowercased())
        }
    }

    static func run(_ a: BenchArgs) async throws {
        guard let dir = a["fixture"] else { throw BenchError("--fixture required") }
        let tier = a["tier"] ?? "T1"
        let cap = tier == "T2" ? "T2-24" : tier
        let key = a["model"] ?? "chat-9b-q4+vision"
        let slot = DevSlots.slot(key)
        let items = try String(contentsOfFile: dir + "/answers.jsonl", encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
        let limit = a.int("limit", items.count)
        let prep = ImageInputPreparer(directory: FileManager.default.temporaryDirectory.appendingPathComponent("antichat-bench-xfer"))
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        _ = try await client.ensureConnected()
        if let gb = DevSlots.tierB[cap], gb > 0 { try await client.setPolicy(SetPolicy(budgetB: UInt64(gb * 1e9))) }
        if let err = await client.warmup(slot) { throw BenchError("warmup: \(err)") }
        let composer = PromptComposer()
        var rows: [[String: Any]] = []
        var correct = 0
        for item in items.prefix(limit) {
            let png = try prep.prepare(URL(fileURLWithPath: dir + "/" + item.file))
            let user = ChatMessage(role: .user, content: item.question + " Answer briefly.", imagePaths: [png.path])
            let req = composer.compose(PromptInputs(), context: VolatileContext()).request(
                sessionID: UUID(), modelSlot: slot, conversation: [user], sampling: Sampling(temperature: 0, maxTokens: 96, seed: 7))
            let t = try await PrefixBench.turn(client, req)
            let ok = score(t.text, item)
            if ok { correct += 1 }
            rows.append(["file": item.file, "answer": item.answer, "normaliser": item.normaliser, "text": String(t.text.prefix(300)),
                         "correct": ok, "ttft_ms": t.ttftAppMs])
            say("\(item.file) \(ok ? "ok" : "MISS") \(t.text.prefix(80).replacingOccurrences(of: "\n", with: " "))")
        }
        let n = min(limit, items.count)
        let acc = Double(correct) / Double(max(1, n))
        let out: [String: Any] = ["cmd": "vision-qa", "model": key, "tier": tier, "cap": cap, "n": n, "correct": correct,
                                  "accuracy": acc, "pass": acc >= 0.90, "vision_parts_per_turn": 1,
                                  "date": ISO8601DateFormatter().string(from: Date()), "rows": rows]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let u = URL(fileURLWithPath: a["out"] ?? "vision-qa.json")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        say("accuracy \(acc) (\(correct)/\(n)) → \(u.path)")
    }
}
