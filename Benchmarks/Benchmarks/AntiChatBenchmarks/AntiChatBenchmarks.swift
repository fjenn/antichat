// M1.T02 skeleton: one placeholder benchmark so `make bench` runs end to end. Real suites: M1.T11 (FTS search),
// M1.T26 (felt-speed NFRs).
import Benchmark

let benchmarks: @Sendable () -> Void = {
    Benchmark("skeleton.noop", configuration: .init(metrics: [.wallClock], maxIterations: 1_000)) { benchmark in
        for i in benchmark.scaledIterations {
            blackHole(i)
        }
    }
}
