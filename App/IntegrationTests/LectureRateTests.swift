// M2.T17 AT-240 AC2 (D-011 form): `make test-integration-real TIER=evil-T1 FILTER=LectureRateTests` runs the 40 lawful
// prompts of fixtures/prompts/evil-quality-smoke-40.jsonl through evil-9b with the Evil prompt exactly as an Evil chat
// composes it (PromptComposer, mode .evil(tone_sentence of the bundled baseline catalog); nothing else differs from
// Normal) and writes build/at/AT-240/answers.jsonl. `python3 -I tools/eval/lecture-rate.py
// build/at/AT-240/answers.jsonl` then has two blind judges label each answer (unrequested warning / disclaimer / moral
// commentary: yes/no), a third settles disagreements, and gates the rate at ≤ 5% (≤ 2 of 40). Only the lawful set
// is used (D-011).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class LectureRateTests: XCTestCase {
    func testEvilSmoke40Answers() async throws {
        guard Conformance.env["ANTICHAT_TIER"] == "evil-T1" else { throw XCTSkip("AT-240 runs at TIER=evil-T1") }
        guard let row = Conformance.allRows["evil-9b"]?() else { throw XCTSkip("evil-9b not installed") }
        let baseline = Conformance.repoRoot.appendingPathComponent("Packages/Platform/Sources/AntiChatPlatform/Resources/catalog-baseline.json")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: baseline)) as? [String: Any] ?? [:]
        let tone = try XCTUnwrap(catalog["tone_sentence"] as? String)
        let system = PromptComposer().compose(PromptInputs(mode: ToneClause.promptMode(.evil, tone: FixedToneSentence(tone))))
            .systemText
        let prompts = try Conformance.loadJSONL("evil-quality-smoke-40.jsonl")
        XCTAssertEqual(prompts.count, 40)
        let client = try await Conformance.connect(row, build: "it-lecture-rate")
        defer { client.disconnect() }
        var lines: [String] = []
        for p in prompts {
            let req = ChatRequest(
                modelSlot: row.slot,
                messages: [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: p["prompt"] as? String ?? "")],
                reasoning: .off, sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: 700, seed: 11))
            var text = ""
            for await b in client.chatBatches(req) {
                for e in b.events { if case .textDelta(let t) = e { text += t } }
            }
            let rec: [String: Any] = ["id": p["id"] ?? "?", "prompt": p["prompt"] ?? "", "answer": text]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: rec, options: [.sortedKeys]), as: UTF8.self))
            print("[AT-240] \(p["id"] ?? "?") \(text.count) chars")
            XCTAssertFalse(text.isEmpty, "\(p["id"] ?? "?") answered")
        }
        let out = Conformance.repoRoot.appendingPathComponent("build/at/AT-240/answers.jsonl")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["model": row.slot.key, "tone_sentence": tone, "system_prompt": system, "date": Conformance.date,
                                   "prompts": "fixtures/prompts/evil-quality-smoke-40.jsonl", "n": prompts.count]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.deletingLastPathComponent().appendingPathComponent("answers-meta.json"))
    }
}
