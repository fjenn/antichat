// AT-034 AC1/AC2 unit leg (R-034, NFR-P5; M4.T15 step 7): Remove background (Apple Vision foreground instance mask)
// against EXACT ground truth — IoU ≥ 0.9 on each of the 10 `fixtures/images/bg-removal/` composites (CC0 scene
// backgrounds + a framed panel subject; masks by construction, see that folder's SOURCES.md) — and its time at 1024²
// (the NFR-P5 number itself is measured by `make perf METRIC=P5` under gpu-run.sh timing; here it is only logged).
// The cutout's alpha is the mask: transparent outside the subject, opaque inside. Vision is built into macOS: no
// model download, so this runs in the ordinary unit suite.
import CoreGraphics
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct RemoveBackgroundTests {
    static var dir: URL { RealPhoto.fixtures.appendingPathComponent("images/bg-removal") }

    static func iou(_ pred: CGImage, _ truth: CGImage) -> Double {
        let w = truth.width, h = truth.height
        let p = MaskCompositor.gray(pred, width: w, height: h), t = MaskCompositor.gray(truth, width: w, height: h)
        var inter = 0, uni = 0
        for i in 0..<(w * h) {
            let a = p[i] > 127, b = t[i] > 127
            if a && b { inter += 1 }
            if a || b { uni += 1 }
        }
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: RemoveBackgroundTests.dir.appendingPathComponent("mask-01.png").path)))
    func iouAgainstGroundTruth() throws {
        var lines: [String] = [], fails: [String] = [], times: [Double] = []
        for i in 1...10 {
            let n = String(format: "%02d", i)
            let img = try #require(RealPhoto.load(Self.dir.appendingPathComponent("composite-\(n).png")))
            let truth = try #require(RealPhoto.load(Self.dir.appendingPathComponent("mask-\(n).png")))
            let t0 = ContinuousClock.now
            let mask = try ForegroundMask.mask(for: img)
            let d = ContinuousClock.now - t0
            times.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            guard let mask else { fails.append("\(n): no subject"); lines.append("\(n) no subject"); continue }
            let v = Self.iou(mask, truth)
            lines.append(String(format: "%@ IoU %.3f %.2f s", n, v, times.last!))
            if v < 0.9 { fails.append(String(format: "%@: %.3f", n, v)) }
            // The cutout carries the mask as alpha.
            let cut = try #require(ForegroundMask.cutout(img, mask: mask))
            let alpha = MaskCompositor.rgba(cut, width: 64, height: 64)
            #expect(alpha[3] == 0, "corner (background) is transparent")
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        let summary = "RemoveBackgroundTests 1024² composites: \(lines.joined(separator: " · ")) | median \(String(format: "%.2f", median)) s (unit run, not the P5 measurement)"
        print(summary)
        let at = RealPhoto.repo.appendingPathComponent("build/at/AT-034")
        try? FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        try? (summary + "\n").write(to: at.appendingPathComponent("remove-background-iou.txt"), atomically: true, encoding: .utf8)
        #expect(fails.isEmpty, "IoU below 0.9: \(fails)")
    }

    @Test func noSubjectIsNil() throws {
        // A flat grey picture has no subject.
        let px = [UInt8](repeating: 128, count: 256 * 256 * 4)
        let flat = try #require(MaskCompositor.image(rgba: px, width: 256, height: 256))
        #expect(try ForegroundMask.mask(for: flat) == nil)
    }
}

/// AT-NFR-P5 (remove background at 1024², Vision path, 20 runs): the full local operation (decode → mask → cutout →
/// PNG) on composite 01, warm. Timing number: run only under `gpu-run.sh timing` (load average recorded with it):
///   ANTICHAT_PERF=1 ANTICHAT_FIXTURES=$PWD/fixtures ~/AntiChat-tools/gpu-run.sh timing -- swift test --filter RemoveBackgroundTimingTests
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_PERF"] == "1")) struct RemoveBackgroundTimingTests {
    @Test func p5At1024() throws {
        let data = try Data(contentsOf: RemoveBackgroundTests.dir.appendingPathComponent("composite-01.png"))
        _ = try ForegroundMask.removeBackground(data)  // warm-up
        var t: [Double] = []
        for _ in 0..<20 {
            let t0 = ContinuousClock.now
            _ = try ForegroundMask.removeBackground(data)
            let d = ContinuousClock.now - t0
            t.append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        let s = t.sorted()
        let line = String(format: "RemoveBackgroundTimingTests P5 1024² 20 runs: median %.3f s p90 %.3f s max %.3f s; load avg %@",
                          s[10], s[18], s.last!, RealPhoto.loadAverage())
        print(line)
        let at = RealPhoto.repo.appendingPathComponent("build/at/AT-NFR-P5")
        try? FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        try? (line + "\n").write(to: at.appendingPathComponent("p5-unit-timing.txt"), atomically: true, encoding: .utf8)
    }
}
