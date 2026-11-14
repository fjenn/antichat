// swift-tools-version: 6.2
// S-3 in-process baseline (M0.T04 step 9). Spike branch only: links AntiChatEngines in-process, which the
// app never does (architecture §3 rule 1). Built with xcodebuild so mlx-swift's Metal library is compiled
// (`swift build` cannot compile .metal sources; A-M0-13).
import PackageDescription

let package = Package(
    name: "antichat-bench-inproc",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "AntiChatKit", path: "../..")],
    targets: [
        .executableTarget(
            name: "antichat-bench-inproc",
            dependencies: [.product(name: "AntiChatEngines", package: "AntiChatKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
