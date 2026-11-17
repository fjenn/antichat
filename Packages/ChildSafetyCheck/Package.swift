// swift-tools-version: 6.2
// ChildSafetyCheck: the single permitted content check (D-006, R-285). Standalone package:
// depends only on onnxruntime + Apple Vision and sees no AntiChat or vendored symbol
// (architecture.md §1.1). Imported only by AntiChatEngines/Media/MediaOutputGate.swift.
// `csc-bench` is a package-internal executable (no product): calibration and latency
// harness for M0.T08 / M4 (docs/prd/M0.md M0.T08).
import PackageDescription

let package = Package(
    name: "ChildSafetyCheck",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "ChildSafetyCheck", targets: ["ChildSafetyCheck"]),
    ],
    dependencies: [
        .package(path: "../../ThirdParty/onnxruntime-swift-package-manager"),  // upstream repo gone (404), see ThirdParty/README.md
    ],
    targets: [
        // C shim over the ONNX Runtime C API (fixed-shape overrides for the CoreML EP; see csc_ort.h).
        .target(
            name: "CSCOrt",
            dependencies: [.product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")]
        ),
        .target(
            name: "ChildSafetyCheck",
            dependencies: ["CSCOrt"],
            resources: [.copy("Resources/thresholds.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "csc-bench",
            dependencies: ["ChildSafetyCheck"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ChildSafetyCheckTests",
            dependencies: ["ChildSafetyCheck"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
