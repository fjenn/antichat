// M2.T22 step 6 (R-235 AC2, AT-235 part 1 bench leg): the CPU part of the pre-router — RouteScorer over the bundled
// prototypes (1,145 rows × 1024 dims, the Qwen3-Embedding width) with a precomputed message vector: Accelerate
// mat-vec, top-k mean per route, rules layer. The GPU part (the helper's embed request over XPC) needs the app bundle
// and the real model: `antichat-bench router --runs 100 --cap T1` (tools/router/bench.sh combines both and writes
// `bench.router.S1scaled.p95`). Threshold: Benchmarks/thresholds/RouterBench.json.
// Run: make bench FILTER=RouterBench
import AntiChatHarness
import Benchmark
import Foundation

/// Deterministic 1024-d vectors (hashed character trigrams): the scorer's cost does not depend on the vectors' meaning.
private struct HashEmbedding: RouteEmbedding {
    var modelID: String? { "hash-1024" }
    func embed(_ texts: [String]) async throws -> [[Float]] { texts.map(Self.vector) }
    static func vector(_ s: String) -> [Float] {
        var v = [Float](repeating: 0, count: 1024)
        let c = Array(" " + s.lowercased() + " ")
        for i in 0..<max(0, c.count - 2) {
            var h: UInt32 = 2166136261
            for ch in c[i..<i + 3] { for u in ch.unicodeScalars { h = (h ^ u.value) &* 16777619 } }
            v[Int(h % 1024)] += 1
        }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}

private let messages = ["draw me a fox in the snow", "what's the weather in Porto today?", "export this as a PDF",
                        "remember my son is allergic to nuts", "maak een korte video van de zee", "explique la relativité"]

let benchmarks: @Sendable () -> Void = {
    Benchmark("RouterBench.cpu",
              configuration: .init(metrics: [.wallClock], timeUnits: .microseconds, warmupIterations: 0,
                                   maxDuration: .seconds(10), maxIterations: 50,
                                   thresholds: [.wallClock: .init(absolute: [.p99: 30_000_000])])) { benchmark in
        guard let p = RoutePrototypes.bundled else { fatalError("RouterBench: route-prototypes.json missing") }
        let scorer = RouteScorer(prototypes: p, embedding: HashEmbedding(), cacheDirectory: nil)
        guard await scorer.prepare() else { fatalError("RouterBench: prepare failed") }
        let vectors = messages.map(HashEmbedding.vector)
        benchmark.startMeasurement()
        for i in benchmark.scaledIterations {
            blackHole(await scorer.scores(for: vectors[i % vectors.count], hasImage: false))
        }
        benchmark.stopMeasurement()
    }
}
