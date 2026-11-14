// AT-034 AC4 real-model legs (R-034; M4.T15 step 7), `@realModels` — opt-in:
//   ANTICHAT_REAL_ERASE=1 ANTICHAT_FIXTURES=$PWD/fixtures ~/AntiChat-tools/gpu-run.sh shared -- \
//     swift test --filter 'MaskFidelityTests'                         (accuracy)
//   ANTICHAT_REAL_ERASE=1 ~/AntiChat-tools/gpu-run.sh timing -- swift test --filter 'EraseTimingTests'   (latency)
// `img-erase` = LaMa Core ML from the dev model cache (`img-erase/LaMa.mlpackage`, pinned 5ed76e3).
//   * MaskFidelityTests: Erase on the 5 edit goldens (source + golden mask) — mean |diff| outside the 8-px-dilated mask
//     ≤ 1/255 (MaskCompositor), and the masked region actually changed (> 8/255 inside).
//   * EraseTimingTests: 1024² erase (crop → 800² → LaMa → back → composite), warm, 10 runs; median vs the 2 s bar
//     (S1-scaled per tools/perf/scale.py at report time; this Mac's class is recorded with the number).
// Outputs stay in memory (numbers only, D-006).
import CoreGraphics
import Foundation
import Testing
@testable import AntiChatEngines

enum RealErase {
    static let enabled = ProcessInfo.processInfo.environment["ANTICHAT_REAL_ERASE"] == "1"
    static var package: URL {
        if let p = ProcessInfo.processInfo.environment["ANTICHAT_ERASE_MODEL"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return RealPhoto.models.appendingPathComponent("img-erase/LaMa.mlpackage")
    }
    static func eraser() -> LaMaEraser {
        LaMaEraser(modelPackage: package, cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("lama-test-cache"))
    }
    static func log(_ line: String) {
        print(line)
        let dir = RealPhoto.repo.appendingPathComponent("build/at/AT-034")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("real-legs.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close() }
        else { try? Data(stamped.utf8).write(to: url) }
    }
}

@Suite(.serialized, .enabled(if: RealErase.enabled)) struct MaskFidelityTests {
    @Test func eraseKeepsEverythingOutsideTheDilatedMask() async throws {
        try #require(FileManager.default.fileExists(atPath: RealErase.package.path), "img-erase not in the dev cache")
        let lama = RealErase.eraser()
        var fails: [String] = []
        for g in try RealPhoto.goldens() {
            let src = try #require(RealPhoto.load(RealPhoto.sourceURL(g)))
            let mask = try #require(RealPhoto.load(RealPhoto.maskURL(g)))
            let t0 = ContinuousClock.now
            let out = try await lama.erase(source: src, mask: mask)
            let d = ContinuousClock.now - t0
            // Re-decode what would be written (PNG round trip), then compare with the source.
            let png = try #require(MaskCompositor.png(out))
            let written = try #require(MaskCompositor.decode(png))
            let outside = MaskCompositor.meanAbsDiffOutside(src, written, mask: mask)
            let inside = MaskCompositor.meanAbsDiffInside(src, written, mask: mask)
            let ok = outside <= 1 && inside > 8
            RealErase.log(String(format: "MaskFidelityTests %@ outside %.4f/255 (bar ≤ 1) inside %.1f/255 (> 8) %.2f s %@", g.id, outside,
                                 inside, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18, ok ? "PASS" : "FAIL"))
            if !ok { fails.append(g.id) }
        }
        #expect(fails.isEmpty, "\(fails)")
    }
}

@Suite(.serialized, .enabled(if: RealErase.enabled)) struct EraseTimingTests {
    @Test func erase1024Warm() async throws {
        try #require(FileManager.default.fileExists(atPath: RealErase.package.path), "img-erase not in the dev cache")
        let lama = RealErase.eraser()
        let g = try #require(try RealPhoto.goldens().first { $0.id == "03-cat" })
        let src = try #require(RealPhoto.load(RealPhoto.sourceURL(g)))
        let mask = try #require(RealPhoto.load(RealPhoto.maskURL(g)))
        let t0 = ContinuousClock.now
        try await lama.preload()
        let load = ContinuousClock.now - t0
        _ = try await lama.erase(source: src, mask: mask)  // warm-up
        var times: [Double] = []
        for _ in 0..<10 {
            let t = ContinuousClock.now
            _ = try await lama.erase(source: src, mask: mask)
            let d = ContinuousClock.now - t
            times.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        let s = times.sorted()
        let loadAvg = RealPhoto.loadAverage()
        RealErase.log(String(format: "EraseTimingTests 1024² (%dx%d) median %.3f s p90 %.3f s max %.3f s (bar 2 s S1-scaled); load+compile %.2f s; load avg %@",
                             src.width, src.height, s[s.count / 2], s[Int(Double(s.count) * 0.9)], s.last!,
                             Double(load.components.seconds) + Double(load.components.attoseconds) / 1e18, loadAvg))
        #expect(s[s.count / 2] <= 2.0)
    }
}
