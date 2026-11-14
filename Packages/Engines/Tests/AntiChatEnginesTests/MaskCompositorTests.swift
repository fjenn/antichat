// AT-034 AC4 unit leg (R-034; M4.T15 step 7): MaskCompositor keeps every pixel outside the 8-px-dilated mask from the
// source (mean |diff| ≤ 1/255; here exactly 0) and takes the engine's pixels inside it; dilation and the crop rule of
// the eraser; plus the `local` job path through the runner (no detectors installed → fails closed, nothing written).
// Synthetic, content-free bitmaps only.
import AntiChatEngineProtocol
import CoreGraphics
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct MaskCompositorTests {
    static func solid(_ w: Int, _ h: Int, _ rgb: (UInt8, UInt8, UInt8)) -> CGImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { px[i * 4] = rgb.0; px[i * 4 + 1] = rgb.1; px[i * 4 + 2] = rgb.2 }
        return MaskCompositor.image(rgba: px, width: w, height: h)!
    }

    static func noise(_ w: Int, _ h: Int, seed: UInt64) -> CGImage {
        var s = seed
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 { s = s &* 6364136223846793005 &+ 1442695040888963407; px[i * 4 + c] = UInt8(truncatingIfNeeded: s >> 56) }
        }
        return MaskCompositor.image(rgba: px, width: w, height: h)!
    }

    /// A soft (feathered) disc mask, top-left origin.
    static func disc(_ w: Int, _ h: Int, cx: Int, cy: Int, r: Int) -> CGImage {
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let d = (Double((x - cx) * (x - cx) + (y - cy) * (y - cy))).squareRoot()
                px[y * w + x] = d <= Double(r) ? 255 : d <= Double(r + 4) ? UInt8(255 * (Double(r + 4) - d) / 4) : 0
            }
        }
        return MaskCompositor.image(gray: px, width: w, height: h)!
    }

    @Test func outsideTheDilatedMaskIsTheSource() throws {
        let src = Self.noise(256, 192, seed: 1), eng = Self.noise(256, 192, seed: 2)
        let mask = Self.disc(256, 192, cx: 100, cy: 80, r: 30)
        let out = try #require(MaskCompositor.composite(source: src, engine: eng, mask: mask))
        #expect(out.width == 256 && out.height == 192)
        let outside = MaskCompositor.meanAbsDiffOutside(src, out, mask: mask)
        #expect(outside <= 1, "outside mean |diff| \(outside)/255 (bar ≤ 1/255)")
        #expect(outside == 0)
        // Inside the mask the engine's pixels are used.
        #expect(MaskCompositor.meanAbsDiffInside(eng, out, mask: mask) == 0)
        #expect(MaskCompositor.meanAbsDiffInside(src, out, mask: mask) > 20)
    }

    /// Round 2: a feathered edge — inside the dilated mask the engine, a blend over `feather` px, the source beyond.
    @Test func featheredEdgeBlendsThenStops() throws {
        let src = Self.solid(64, 64, (0, 0, 0)), eng = Self.solid(64, 64, (255, 255, 255))
        var m = [UInt8](repeating: 0, count: 64 * 64)
        m[32 * 64 + 32] = 255
        let mask = try #require(MaskCompositor.image(gray: m, width: 64, height: 64))
        let out = try #require(MaskCompositor.composite(source: src, engine: eng, mask: mask))
        let px = MaskCompositor.rgba(out, width: 64, height: 64)
        func r(_ x: Int) -> UInt8 { px[(32 * 64 + x) * 4] }
        #expect(r(32 + MaskCompositor.dilation) == 255, "core: engine")
        #expect(r(32 + MaskCompositor.dilation + 1) > 0 && r(32 + MaskCompositor.dilation + 1) < 255, "feather: blend")
        #expect(r(32 + MaskCompositor.dilation + MaskCompositor.feather + 1) == 0, "beyond the band: source")
        #expect(MaskCompositor.maxAbsDiffOutside(src, out, mask: mask) == 0)
    }

    @Test func engineOutputAtAnotherSizeIsResampled() throws {
        let src = Self.solid(300, 200, (10, 20, 30)), eng = Self.solid(64, 64, (200, 100, 50))
        let mask = Self.disc(300, 200, cx: 150, cy: 100, r: 20)
        let out = try #require(MaskCompositor.composite(source: src, engine: eng, mask: mask))
        #expect(out.width == 300 && out.height == 200)
        #expect(MaskCompositor.meanAbsDiffOutside(src, out, mask: mask) == 0)
    }

    @Test func dilationGrowsByTheRadius() {
        var m = [UInt8](repeating: 0, count: 41 * 41)
        m[20 * 41 + 20] = 1
        let d = MaskCompositor.dilated(m, width: 41, height: 41, radius: 8)
        #expect(d.filter { $0 == 255 }.count == 17 * 17, "a single pixel grows to a 17×17 square")
        #expect(d[20 * 41 + 28] == 255 && d[20 * 41 + 29] == 0)
    }

    @Test func eraserCropIsASquareAroundTheMask() throws {
        var m = [UInt8](repeating: 0, count: 1000 * 800)
        for y in 300..<400 { for x in 500..<700 { m[y * 1000 + x] = 255 } }
        let r = try #require(LaMaEraser.crop(maskPixels: m, width: 1000, height: 800))
        #expect(r.width == 300 && r.height == 300, "1.5 × the 200 px long side")
        #expect(r.minX <= 500 && r.maxX >= 700 && r.minY <= 300 && r.maxY >= 400)
        #expect(LaMaEraser.crop(maskPixels: [UInt8](repeating: 0, count: 100), width: 10, height: 10) == nil)
        // Near an edge: clamped inside the picture, at least 256 px.
        var e = [UInt8](repeating: 0, count: 600 * 600)
        e[5 * 600 + 5] = 255
        let c = try #require(LaMaEraser.crop(maskPixels: e, width: 600, height: 600))
        #expect(c.minX == 0 && c.minY == 0 && c.width == 256)
    }

    /// A `local` job goes through the runner and the gate like any output: without detectors it fails closed — nothing
    /// is written (one result check, no preview check).
    @Test func localJobWithoutDetectorsWritesNothing() async throws {
        let dir = RunnerHarness.temp("local")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("src.png")
        try MaskCompositor.png(Self.noise(128, 128, seed: 3))!.write(to: src)
        let mask = dir.appendingPathComponent("mask.png")
        try MaskCompositor.png(Self.disc(128, 128, cx: 64, cy: 64, r: 10))!.write(to: mask)
        var req = ImageRequest(model: ImageModelSet(key: "img-erase", diffusionModel: "", llm: "", vae: "", footprintBytes: 0),
                               prompt: "", width: 128, height: 128, steps: 1, seed: 0, preview: "none",
                               outputPath: dir.appendingPathComponent("out/result.png").path)
        req.initImagePath = src.path
        req.maskImagePath = mask.path
        req.localOperation = LocalImageJob.erase
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        // A fake eraser that "fills" with the engine noise: the composite is computed, then the gate (no detectors) withholds.
        let terminal = await runner.run(MediaJobSubmit(job: "local-1", kind: .local, image: req, safety: nil), emit: { _ in }) { o in
            guard let s = MaskCompositor.decode(try Data(contentsOf: src)), let m = MaskCompositor.decode(try Data(contentsOf: mask)),
                  let c = MaskCompositor.composite(source: s, engine: Self.noise(128, 128, seed: 9), mask: m) else { return .completed }
            _ = await o.result(MaskCompositor.png(c)!)
            return .completed
        }
        if case .safetyMissing = terminal {} else { Issue.record("expected safetyMissing, got \(terminal)") }
        let results = await runner.gateCalls(.result), previews = await runner.gateCalls(.preview)
        #expect(results == 1 && previews == 0)
        #expect(!FileManager.default.fileExists(atPath: req.outputPath))
    }
}
