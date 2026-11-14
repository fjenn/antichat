// swift-tools-version: 6.2
// S-4 comparison only (M0.T04 step 12; spike/s-4-vmlx). osaurus-ai/vmlx-swift @ 88e25dc673 (the revision
// Osaurus pins, engines.md §Osaurus row). vmlx-swift ships its own MLXLMCommon/MLXLLM modules, so it
// cannot sit next to mlx-swift-lm in AntiChatKit; this standalone bench runs the same in-process protocol
// as tools/antichat-bench-inproc (A-M0-10). MLXHuggingFace (macros) is not used: Xcode refuses an
// unvalidated package macro and skipping validation was refused (Q-014), so main.swift bridges VMLXTokenizers itself. Never on main; pulls swift-nio / async-http-client.
import PackageDescription

let package = Package(
    name: "antichat-bench-vmlx",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/osaurus-ai/vmlx-swift", revision: "88e25dc6735b03d51fdcb495aaaede7b0e77fd26"),
    ],
    targets: [
        .executableTarget(
            name: "antichat-bench-vmlx",
            dependencies: [
                .product(name: "MLX", package: "vmlx-swift"),
                .product(name: "MLXRandom", package: "vmlx-swift"),
                .product(name: "MLXLMCommon", package: "vmlx-swift"),
                .product(name: "MLXLLM", package: "vmlx-swift"),
                .product(name: "MLXVLM", package: "vmlx-swift"),
                .product(name: "VMLXTokenizers", package: "vmlx-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
