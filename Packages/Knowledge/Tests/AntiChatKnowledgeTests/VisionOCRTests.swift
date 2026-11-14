// AT-271 check 3 (R-271 AC3; M6.T04 steps 2/6): Vision OCR over the degraded scans. 3a: every `ocr-30p` page is
// recognised (RecognizeDocumentsRequest → Markdown) and written to build/at/AT-271/<date>/ocr/page-NN.md, then mean
// CER ≤ 3 % (also scored by `python3 -I tools/at/cer.py --gt fixtures/docs/ocr-30p --pred …/ocr --out …/cer.json`).
// 3b: `tables-20` pages come back as Markdown tables whose row and column counts match tables-20.gt.json on ≥ 18/20.
// Plus the step 4 queue: pages in order, paused between pages while OCRPause is set, `.fast` on T0 above 50 pages.
//   make test-unit FILTER=VisionOCRTests
import Foundation
import PDFKit
import Testing
@testable import AntiChatKnowledge

@Suite(.serialized) struct VisionOCRTests {
    static var outDir: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return dir.appendingPathComponent("build/at/AT-271/\(f.string(from: Date()))", isDirectory: true)
    }

    static func ocr(_ rel: String) async throws -> String {
        let page = try #require(PDFDocument(url: IntakeFixtures.url(rel))?.page(at: 0))
        let image = try #require(VisionOCR.render(page))
        return await VisionOCR().recognize(image)
    }

    static func normalise(_ s: String) -> [Character] {
        var lines: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var t = raw.trimmingCharacters(in: .whitespaces)
            if t.wholeMatch(of: /\|?(\s*-{3,}\s*\|)+\s*-*/) != nil { continue }
            t = t.replacing(/^#+\s*/, with: "").replacing(/^[-*]\s+/, with: "").replacingOccurrences(of: "|", with: " ")
            lines.append(t)
        }
        return Array(lines.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " "))
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var cur = [i + 1]
            cur.reserveCapacity(b.count + 1)
            for (j, cb) in b.enumerated() { cur.append(min(prev[j + 1] + 1, cur[j] + 1, prev[j] + (ca == cb ? 0 : 1))) }
            prev = cur
        }
        return prev[b.count]
    }

    @Test func cerOverThirtyScannedPagesIsAtMostThreePercent() async throws {
        let dir = Self.outDir.appendingPathComponent("ocr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var cers: [Double] = []
        for i in 1...30 {
            let name = String(format: "page-%02d", i)
            let md = try await Self.ocr("docs/ocr-30p/\(name).pdf")
            try Data(md.utf8).write(to: dir.appendingPathComponent("\(name).md"))
            let gt = try String(contentsOf: IntakeFixtures.url("docs/ocr-30p/\(name).gt.txt"), encoding: .utf8)
            let g = Self.normalise(gt), p = Self.normalise(md)
            cers.append(Double(Self.levenshtein(p, g)) / Double(max(1, g.count)))
        }
        let mean = cers.reduce(0, +) / Double(cers.count)
        let json = try JSONSerialization.data(withJSONObject: ["mean_cer": mean, "pages": cers], options: [.prettyPrinted])
        try json.write(to: Self.outDir.appendingPathComponent("cer-swift.json"))
        #expect(mean <= 0.03, "mean CER \(mean); worst \(cers.max() ?? 0)")
    }

    /// Row/column counts of the first Markdown table in `md` (separator row excluded).
    static func tableShape(_ md: String) -> (rows: Int, cols: Int)? {
        let lines = md.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { $0.hasPrefix("|") }) else { return nil }
        let table = lines[start...].prefix { $0.hasPrefix("|") }
        let rows = table.filter { $0.wholeMatch(of: /\|(\s*-{3,}\s*\|)+/) == nil }
        guard let first = rows.first else { return nil }
        let cols = first.replacingOccurrences(of: "\\|", with: "").filter { $0 == "|" }.count - 1
        return (rows.count, cols)
    }

    @Test func tablesComeBackAsMarkdownTablesOfTheRightShape() async throws {
        let dir = Self.outDir.appendingPathComponent("tables", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gt = try JSONDecoder().decode([String: [String: Int]].self,
                                          from: Data(contentsOf: IntakeFixtures.url("docs/tables-20.gt.json")))
        var ok = 0
        var rows: [[String: Any]] = []
        for (name, want) in gt.sorted(by: { $0.key < $1.key }) {
            let md = try await Self.ocr("docs/tables-20/\(name)")
            try Data(md.utf8).write(to: dir.appendingPathComponent(name.replacingOccurrences(of: ".pdf", with: ".md")))
            let got = Self.tableShape(md)
            let match = got?.rows == want["rows"] && got?.cols == want["cols"]
            if match { ok += 1 }
            rows.append(["file": name, "want": want, "got": got.map { ["rows": $0.rows, "cols": $0.cols] } ?? [:], "match": match])
        }
        let json = try JSONSerialization.data(withJSONObject: ["matched": ok, "of": gt.count, "rows": rows], options: [.prettyPrinted])
        try json.write(to: Self.outDir.appendingPathComponent("tables.json"))
        #expect(ok >= 18, "\(ok)/20 tables shape-exact")
    }

    @Test func queueRunsInOrderAndWaitsWhilePaused() async throws {
        let pause = OCRPause()
        var q = OCRQueue(pause: pause)
        q.pausePoll = .milliseconds(20)
        let url = IntakeFixtures.url("docs/pdf/scan-60p-contract.pdf")
        pause.set(true)
        let stream = q.run(url: url, pages: [1, 2], level: .fast)
        let collector = Task { var out: [OCRProgress] = []; for await p in stream { out.append(p) }; return out }
        try await Task.sleep(for: .milliseconds(300))
        pause.set(false)
        let got = await collector.value
        #expect(got.map(\.page) == [1, 2] && got.map(\.done) == [1, 2] && got.allSatisfy { $0.total == 2 })
        #expect(got[0].markdown.contains("Clause 1"), "\(got[0].markdown.prefix(120))")
        #expect(OCRQueue.level(tier: "T0", pages: 51) == .fast && OCRQueue.level(tier: "T0", pages: 50) == .accurate)
        #expect(OCRQueue.level(tier: "T1", pages: 300) == .accurate)
    }
}
