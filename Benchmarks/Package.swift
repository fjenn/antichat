// swift-tools-version: 6.2
// Test-only benchmark package (P-shell-19, ordo-one/package-benchmark 1.38.1 @ca4a9d3; M1.T02 skeleton).
// Kept OUT of the root AntiChatKit package so its dependencies (swift-argument-parser, swift-system, jemalloc
// opt-out, …) never enter the shipped graph or the root Package.resolved (A-M1-T02a). M1.T11 added the
// `.package(path: "..")` dependency on AntiChatKit (PaletteBenchmarks); M1.T26 adds the felt-speed suites.
// Run: make bench FILTER=<regex>   (= swift package --package-path Benchmarks benchmark --filter …)
import Foundation
import PackageDescription

// M1.T11: the root package as a path dependency (AntiChatHarness for the ⌘K search benchmark). A path dependency's
// identity is its directory name (the checkout or worktree folder), so it is computed, not spelled.
let rootIdentity = URL(fileURLWithPath: Context.packageDirectory).deletingLastPathComponent().lastPathComponent.lowercased()

let package = Package(
    name: "AntiChatBenchmarks",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/package-benchmark", exact: "1.38.1"),
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "AntiChatBenchmarks",
            dependencies: [.product(name: "Benchmark", package: "package-benchmark")],
            path: "Benchmarks/AntiChatBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
        // M1.T11 step 6: ⌘K search on the 10k-chat fixture (thresholds/PaletteSearch.json).
        .executableTarget(
            name: "PaletteBenchmarks",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "AntiChatHarness", package: rootIdentity),
            ],
            path: "Benchmarks/PaletteBenchmarks",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
        // M2.T22 step 6: the pre-router's CPU part (RouteScorer over the bundled prototypes).
        .executableTarget(
            name: "RouterBench",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "AntiChatHarness", package: rootIdentity),
            ],
            path: "Benchmarks/RouterBench",
            plugins: [.plugin(name: "BenchmarkPlugin", package: "package-benchmark")]
        ),
    ]
)
