// `antichat-bench caption-fallback` (M6.T06; AT-237 check 1 real leg, R-237 AC1): the text-only fallback on real
// models. Per item of fixtures/images/needs-ocr-10: Vision OCR of the image, one HelperCaptioner call on the starter
// VLM (chat-0.8b with its vision tower), then the text-only chat model (chat-lfm3) answers from
// `<image_description source="helper" untrusted="true">caption + Text found in image: OCR</image_description>`.
// Informational bar ≥ 8/10 answers contain the gold text; also records the helper's lifetime peak footprint vs the
// tier budget B (DoD, NFR-R1) and that the helper ran exactly once per image.
//
//   antichat-bench caption-fallback --fixture fixtures/images/needs-ocr-10 --tier T0 --out <json>
//                                   [--model chat-lfm3] [--helper chat-0.8b+vision]
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatKnowledge
import Foundation

enum CaptionFallback {
    struct Item: Decodable { var file: String; var question: String; var gold: String }

    static func run(_ a: BenchArgs) async throws {
        guard let dir = a["fixture"] else { throw BenchError("--fixture required") }
        let tier = a["tier"] ?? "T0"
        let cap = tier == "T2" ? "T2-24" : tier
        let chat = DevSlots.slot(a["model"] ?? "chat-lfm3")
        let helper = DevSlots.slot(a["helper"] ?? "chat-0.8b+vision")
        let items = try String(contentsOfFile: dir + "/questions.jsonl", encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
        let client = EngineClient(appBuild: "antichat-bench")
        defer { client.disconnect() }
        let ack = try await client.ensureConnected()
        let budget = UInt64((DevSlots.tierB[cap] ?? 0) * 1e9)
        if budget > 0 { try await client.setPolicy(SetPolicy(budgetB: budget)) }
        let captioner = HelperCaptioner(engine: client, slot: helper, preparer: ImageInputPreparer(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("antichat-bench-xfer")))
        let composer = PromptComposer()
        var rows: [[String: Any]] = []
        var correct = 0
        for item in items {
            let url = URL(fileURLWithPath: dir + "/" + item.file)
            let ocr: String
            if let (img, o) = VisionOCR.image(at: url) { ocr = await VisionOCR().recognize(img, orientation: o) } else { ocr = "" }
            let t0 = ContinuousClock.now
            let caption = await captioner.caption(url.path) ?? ""
            let captionS = Stats.secs(ContinuousClock.now - t0)
            let block = DocumentContextAssembler.imageDescriptionBlock(caption: caption, ocr: ocr)
            let user = ChatMessage(role: .user, content: block + "\n\n" + item.question + " Answer briefly.")
            let req = composer.compose(PromptInputs(), context: VolatileContext()).request(
                sessionID: UUID(), modelSlot: chat, conversation: [user], sampling: Sampling(temperature: 0, maxTokens: 64, seed: 7))
            let t = try await PrefixBench.turn(client, req)
            let ok = t.text.uppercased().contains(item.gold.uppercased())
            if ok { correct += 1 }
            rows.append(["file": item.file, "gold": item.gold, "caption": String(caption.prefix(300)), "ocr_chars": ocr.count,
                         "caption_s": captionS, "answer": String(t.text.prefix(200)), "correct": ok])
            say("\(item.file) \(ok ? "ok" : "MISS") caption \(String(format: "%.1f", captionS)) s · \(t.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        }
        let peak = FilesWarm.lifetimePeakFootprint(pid: ack.helperPID)
        let out: [String: Any] = ["cmd": "caption-fallback", "model": chat.key, "helper": helper.key, "tier": tier, "cap": cap,
                                  "n": items.count, "correct": correct, "bar_8_of_10": correct >= 8,
                                  "helper_calls": items.count, "peak_footprint_bytes": peak, "budget_b_bytes": budget,
                                  "peak_within_b": budget == 0 || (peak > 0 && UInt64(peak) <= budget),
                                  "date": ISO8601DateFormatter().string(from: Date()), "rows": rows]
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        let u = URL(fileURLWithPath: a["out"] ?? "caption-fallback.json")
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: u)
        say("\(correct)/\(items.count) correct, helper peak \(peak / 1_000_000) MB of B \(budget / 1_000_000) MB → \(u.path)")
    }
}
