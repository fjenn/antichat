// M2.T15 AT-239 part 2 (R-239 AC2): Evil passes the R-229 tool-conformance suite within 5 points of Normal.
// `make test-integration-real TIER=evil-T1 FILTER=EvilConformanceTests` (evil-9b on llama-server vs chat-9b-q4 on
// MLX, T1 cap) and `TIER=evil-T3` (evil-35b-q4 vs chat-35b-q4, both MLX, T3 cap). Per model, the M1 suite (tools-40,
// thinking-20, cancel-10; App/IntegrationTests/Conformance) plus agentic-30 and bfcl-subset-100 (their rows of
// antichat-tools-200, ToolEvalRunner: a row is valid when the called tools are the expected ones, every call is
// schema-valid and no raw tool syntax leaked). Gate per suite: validity_evil ≥ validity_normal − 5 points. T1 also
// keeps vision: doc-00 of the OCR set (tools/fixtures/make-ocr.py) answered by evil-9b with its mmproj (as M0.T09).
// Writes build/at/AT-239/conformance-T1.json / -T3.json. The request mode is the only Evil input the engine sees
// (the slot); no prompt or filter differs here (R-241).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation
import XCTest

final class EvilConformanceTests: XCTestCase {
    struct Pair { let tier: String; let evil: String; let normal: String }

    static var pair: Pair? {
        switch Conformance.env["ANTICHAT_TIER"] {
        case "evil-T1": Pair(tier: "T1", evil: "evil-9b", normal: "chat-9b-q4")
        case "evil-T3": Pair(tier: "T3", evil: "evil-35b-q4", normal: "chat-35b-q4")
        default: nil
        }
    }

    func testEvilWithinFivePointsOfNormal() async throws {
        continueAfterFailure = true
        guard let pair = Self.pair else { throw XCTSkip("AT-239 part 2 runs at TIER=evil-T1 or evil-T3") }
        guard let evil = Conformance.allRows[pair.evil]?(), let normal = Conformance.allRows[pair.normal]?() else {
            throw XCTSkip("\(pair.evil) / \(pair.normal) not installed (make models-dev TIER=evil-\(pair.tier))")
        }
        let limit = Conformance.env["ANTICHAT_EVIL_CONFORMANCE_LIMIT"].flatMap(Int.init)
        var report: [String: Any] = ["id": "AT-239", "part": 2, "tier": pair.tier, "date": Conformance.date,
                                     "via": "make test-integration-real TIER=evil-\(pair.tier) FILTER=EvilConformanceTests"]
        var suites: [String: [String: Double]] = [:]
        for (mode, row) in [("evil", evil), ("normal", normal)] {
            let r = try await Self.suites(row, limit: limit)
            for (suite, v) in r { suites[suite, default: [:]][mode] = v }
            report[mode] = ["model": row.slot.key, "engine": row.engine, "family": row.family, "cap": row.cap]
        }
        var rows: [[String: Any]] = []
        var pass = true
        for (suite, v) in suites.sorted(by: { $0.key < $1.key }) {
            let e = v["evil"] ?? 0, n = v["normal"] ?? 0
            let ok = e >= n - 5
            pass = pass && ok
            rows.append(["suite": suite, "validity_evil": e, "validity_normal": n, "delta_points": e - n, "pass": ok])
            XCTAssertGreaterThanOrEqual(e, n - 5, "\(suite): Evil \(e)% vs Normal \(n)%")
        }
        report["suites"] = rows
        report["pass"] = pass
        report["limit"] = limit ?? NSNull()
        let out = Conformance.repoRoot.appendingPathComponent("build/at/AT-239/conformance-\(pair.tier)\(limit == nil ? "" : "-limit\(limit!)").json")
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        print("[AT-239] \(rows) → \(out.path)")
    }

    /// T1 vision kept (as M0.T09): doc-00 through evil-9b with its mmproj (the model dir, vision on).
    func testEvilVisionDoc00() async throws {
        guard Self.pair?.tier == "T1" else { throw XCTSkip("the vision leg runs at TIER=evil-T1") }
        guard let evil = Conformance.allRows["evil-9b"]?() else { throw XCTSkip("evil-9b not installed") }
        var row = evil
        row.slot = ModelSlot(engine: .llama, key: "evil-9b", path: Conformance.view("evil-9b").path, vision: true,
                             contextTokens: 16384)
        let v = try await Self.vision(row)
        let out = Conformance.repoRoot.appendingPathComponent("build/at/AT-239/vision-T1.json")
        try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]).write(to: out)
        XCTAssertEqual(v["correct"] as? Bool, true, "evil-9b + mmproj answers doc-00: \(v)")
    }

    /// Validity % per suite for one model.
    static func suites(_ row: ConformanceRow, limit: Int?) async throws -> [String: Double] {
        func pct(_ ok: Int, _ n: Int) -> Double { n == 0 ? 0 : (Double(ok) * 1000 / Double(n)).rounded() / 10 }
        func cut<T>(_ xs: [T]) -> [T] { limit.map { Array(xs.prefix($0)) } ?? xs }
        var out: [String: Double] = [:]
        let client = try await Conformance.connect(row, build: "it-evil-conformance")
        defer { client.disconnect() }
        let tools = cut(try Conformance.loadJSONL("conformance/tools-50.jsonl").filter { ($0["kind"] as? String) != "recovery" })
        var ok = 0
        for c in tools { if await ToolCallCases.run(client, row, c).pass { ok += 1 } }
        out["r229-tools"] = pct(ok, tools.count)
        let thinking = cut(try Conformance.loadJSONL("conformance/thinking-20.jsonl"))
        ok = 0
        for c in thinking { if await ThinkingCases.run(client, row, c)["pass"] as? Bool == true { ok += 1 } }
        out["r229-thinking"] = pct(ok, thinking.count)
        let cancel = cut(try Conformance.loadJSONL("conformance/cancel-10.jsonl"))
        ok = 0
        for c in cancel { if await CancelCases.run(client, row, c)["pass"] as? Bool == true { ok += 1 } }
        out["r229-cancel"] = pct(ok, cancel.count)
        let all = try ToolEvalRunner.loadRows(Conformance.casesDir.appendingPathComponent("antichat-tools-200.jsonl"))
        for (suite, test) in [("agentic-30", { (r: [String: Any]) in (r["id"] as? String ?? "").hasPrefix("ag-") }),
                              ("bfcl-subset-100", { (r: [String: Any]) in (r["id"] as? String ?? "").hasPrefix("bfcl-") })] {
            let rows = cut(all.filter(test))
            let rep = await ToolEvalRunner.run(client: client, slot: row.slot, rows: rows) { print("[\(row.id) \(suite)] \($0)") }
            let cases = rep["cases"] as? [[String: Any]] ?? []
            let valid = cases.filter { c in
                (c["correct"] as? Bool == true) && ((c["schema_valid"] as? [Bool]) ?? []).allSatisfy { $0 }
                    && ((c["leaks"] as? [Any]) ?? []).isEmpty
            }.count
            out[suite] = pct(valid, cases.count)
            print("[\(row.id)] \(suite) \(valid)/\(cases.count)")
        }
        print("[\(row.id)] validity \(out)")
        return out
    }

    /// doc-00 of the OCR set through the Evil model's mmproj.
    static func vision(_ row: ConformanceRow) async throws -> [String: Any] {
        let dir = Conformance.env["ANTICHAT_OCR_DIR"].map { URL(fileURLWithPath: $0) }
            ?? Conformance.repoRoot.appendingPathComponent("build/fixtures-ocr")
        let img = dir.appendingPathComponent("doc-00.png")
        guard FileManager.default.fileExists(atPath: img.path) else {
            throw XCTSkip("\(img.path) missing: tools/.venv/bin/python -I tools/fixtures/make-ocr.py --out build/fixtures-ocr")
        }
        let answers = try String(contentsOf: dir.appendingPathComponent("answers.jsonl"), encoding: .utf8).split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let a = answers.first(where: { $0["file"] as? String == "doc-00.png" }), let want = a["answer"] as? String,
              let q = a["question"] as? String else { throw XCTSkip("doc-00 answer missing") }
        let client = try await Conformance.connect(row, build: "it-evil-vision")
        defer { client.disconnect() }
        let req = ChatRequest(modelSlot: row.slot, messages: [ChatMessage(role: .user, content: q, imagePaths: [img.path])],
                              reasoning: .off, sampling: Sampling(temperature: 0, topP: 1, maxTokens: 200, seed: 7))
        var text = ""
        for await b in client.chatBatches(req) {
            for e in b.events { if case .textDelta(let t) = e { text += t } }
        }
        return ["file": "doc-00.png", "expected": want, "text": String(text.prefix(200)),
                "correct": text.lowercased().contains(want.lowercased())]
    }
}
