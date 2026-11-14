// M7.T02 (AT-249 c2, R-249 AC2): token-level F1 of the HTML extractor against the gold article bodies of
// fixtures/web/extraction-960/articles-50 (scrapinghub/article-extraction-benchmark, MIT). Bar: mean F1 ≥ 0.85.
// Writes build/at/AT-249/f1.json.
@testable import AntiChatTools
import Foundation
import Testing

struct ExtractionF1Tests {
    static let dir = ToolsFixtures.url("web/extraction-960/articles-50")

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Bag-of-tokens precision / recall / F1 (the benchmark's own metric).
    static func f1(_ predicted: String, _ gold: String) -> (p: Double, r: Double, f: Double) {
        let pt = tokens(predicted), gt = tokens(gold)
        guard !pt.isEmpty, !gt.isEmpty else { return (0, 0, pt.isEmpty && gt.isEmpty ? 1 : 0) }
        var g: [String: Int] = [:]
        for t in gt { g[t, default: 0] += 1 }
        var common = 0
        for t in pt where (g[t] ?? 0) > 0 { common += 1; g[t]! -= 1 }
        let p = Double(common) / Double(pt.count), r = Double(common) / Double(gt.count)
        return (p, r, p + r == 0 ? 0 : 2 * p * r / (p + r))
    }

    @Test func meanF1MeetsTheBar() throws {
        let ids = try FileManager.default.contentsOfDirectory(atPath: Self.dir.path).filter { $0.hasSuffix(".html") }
            .map { String($0.dropLast(5)) }.sorted()
        try #require(ids.count == 50, "articles-50 missing (tools/fixtures/make-extraction-50.py)")
        var rows: [[String: Any]] = [], sum = 0.0
        for id in ids {
            let html = try Data(contentsOf: Self.dir.appending(path: "\(id).html"))
            let gold = try String(contentsOf: Self.dir.appending(path: "\(id).gold.txt"), encoding: .utf8)
            let page = FetchedPage(requestedURL: URL(string: "https://article.test/\(id)")!, url: URL(string: "https://article.test/\(id)")!,
                                   status: 200, contentType: "text/html", data: html, fetchedAt: Date(), fromCache: false)
            let text = Extractor.extract(page)?.text ?? ""
            let m = Self.f1(text, gold)
            sum += m.f
            rows.append(["id": id, "precision": m.p, "recall": m.r, "f1": m.f, "method": Extractor.extract(page)?.method ?? "none"])
        }
        let mean = sum / Double(ids.count)
        let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "set": "articles-50", "mean_f1": mean,
                                     "bar": 0.85, "pass": mean >= 0.85, "rows": rows,
                                     "extractor": Extractor.htmlChain.map { String(describing: type(of: $0)) }]
        var out = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { out.deleteLastPathComponent() }
        out = out.appending(path: "build/at/AT-249")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appending(path: "f1.json"))
        print("AT-249 c2 mean F1 = \(mean)")
        #expect(mean >= 0.85, "mean extraction F1 \(mean) < 0.85")
    }
}
