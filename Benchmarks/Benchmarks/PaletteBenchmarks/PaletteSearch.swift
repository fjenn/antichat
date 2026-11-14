// M1.T11 step 6 (NFR-U10, AT-NFR-U10's bench leg): ⌘K full-text search on the 10,000-chat fixture database
// (`build/fixtures/big-10k.sqlite`, tools/fixtures/gen-chats.py; `ANTICHAT_BIG10K_DB` overrides). One iteration =
// one query of the AT-012 list through `ChatListService.search` (FTSSearch: bm25 + snippet), the same call the
// palette makes. Threshold: Benchmarks/thresholds/PaletteSearch.json (p99 ≤ 200 ms wall clock).
// Run: make bench FILTER=PaletteSearch
import AntiChatHarness
import Benchmark
import Foundation

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private struct Threshold: Decodable {
    let metric: String
    let p99_ms: Int
}

private let threshold: Threshold = {
    let url = repoRoot.appendingPathComponent("Benchmarks/thresholds/PaletteSearch.json")
    guard let data = try? Data(contentsOf: url), let t = try? JSONDecoder().decode(Threshold.self, from: data) else {
        fatalError("PaletteSearch: cannot read \(url.path)")
    }
    return t
}()

/// The 20 AT-012 queries (FTSSearchTests.latencyQueries): fixture token, title words, common and rare body words.
private let queries = [
    "zebracorn", "pasta", "tax", "garden", "bike", "swift", "consider", "simple steps", "quality", "measure",
    "example", "detail", "first", "note time", "useful", "check", "result list", "plan", "small start", "repair",
]

/// A private copy of the fixture database (the search never writes, but the app's migrations might).
private func openFixture() -> ChatListService {
    let env = ProcessInfo.processInfo.environment["ANTICHAT_BIG10K_DB"]
    let src = env.map { URL(fileURLWithPath: $0) } ?? repoRoot.appendingPathComponent("build/fixtures/big-10k.sqlite")
    guard FileManager.default.fileExists(atPath: src.path) else {
        fatalError("PaletteSearch: \(src.path) missing (python3 -I tools/fixtures/gen-chats.py)")
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("palette-bench-\(UUID().uuidString)")
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent("antichat.sqlite")
        try FileManager.default.copyItem(at: src, to: copy)
        return try ChatListService.onDisk(at: copy)
    } catch {
        fatalError("PaletteSearch: \(error)")
    }
}

let benchmarks: @Sendable () -> Void = {
    let p99 = Int(threshold.p99_ms) * 1_000_000
    Benchmark("PaletteSearch",
              configuration: .init(metrics: [.wallClock], timeUnits: .milliseconds, warmupIterations: 5,
                                   maxDuration: .seconds(30), maxIterations: 400,
                                   thresholds: [.wallClock: .init(absolute: [.p99: p99])])) { benchmark, service in
        var i = 0
        for _ in benchmark.scaledIterations {
            let hits = try service.search(queries[i % queries.count])
            blackHole(hits)
            i += 1
        }
    } setup: {
        openFixture()
    }
}
