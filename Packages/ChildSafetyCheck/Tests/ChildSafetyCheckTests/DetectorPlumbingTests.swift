// Detector plumbing without content: tensor preprocessing on solid-colour canvases, Apple Vision on a blank
// canvas, and (opt-in, CSC_REAL_DETECTORS=1 with the dev models present) the real ONNX sessions on blank
// frames. No test here uses an image with content (test-strategy §2, D-017); detector accuracy is
// calibration's job (M4.T02), not these tests'.
import CoreGraphics
import Foundation
import Testing
@testable import ChildSafetyCheck

func solid(_ w: Int, _ h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

@Suite struct ImageTensorTests {
    @Test func squashNormalisesPerChannel() throws {
        let t = try ImageTensor.chw(solid(10, 20, r: 1, g: 0, b: 1), side: 8, mode: .squash, mean: [0.5, 0, 0.5], std: [0.5, 1, 0.25])
        #expect(t.count == 3 * 64)
        #expect(t[0..<64].allSatisfy { abs($0 - 1) < 0.02 })      // (1 − 0.5) / 0.5
        #expect(t[64..<128].allSatisfy { abs($0) < 0.02 })        // (0 − 0) / 1
        #expect(t[128..<192].allSatisfy { abs($0 - 2) < 0.05 })   // (1 − 0.5) / 0.25
    }

    @Test func letterboxPadsWithBlack() throws {
        // A 2:1 white image letterboxed into 8×8 fills rows 2…5; rows 0, 1, 6, 7 are black.
        let t = try ImageTensor.chw(solid(16, 8, r: 1, g: 1, b: 1), side: 8, mode: .letterbox, mean: [0, 0, 0], std: [1, 1, 1])
        let red = Array(t[0..<64])
        #expect(red[0..<16].allSatisfy { $0 < 0.02 } && red[48..<64].allSatisfy { $0 < 0.02 })
        #expect(red[24..<40].allSatisfy { $0 > 0.98 })
    }

    @Test func nilImageIsBlackFrame() throws {
        let t = try ImageTensor.chw(nil, side: 4, mode: .letterbox, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5])
        #expect(t.allSatisfy { abs($0 + 1) < 1e-6 })
    }

    @Test func cropClampsAndRejectsEmpty() {
        let img = solid(100, 50, r: 0, g: 0, b: 0)
        #expect(ImageTensor.crop(img, CGRect(x: 90, y: 40, width: 30, height: 30)).map { ($0.width, $0.height) } ?? (0, 0) == (10, 10))
        #expect(ImageTensor.crop(img, CGRect(x: 200, y: 0, width: 10, height: 10)) == nil)
        #expect(ImageTensor.crop(img, CGRect(x: 10, y: 10, width: 0.2, height: 0.2)) != nil)  // integral ⇒ 1 px
    }

    @Test func softmaxSumsToOne() {
        let p = softmax([1, 2, 3, 4])
        #expect(abs(p.reduce(0, +) - 1) < 1e-9 && p == p.sorted())
    }
}

@Suite struct VisionPeopleTests {
    @Test func blankCanvasHasNoPeople() throws {
        let boxes = try VisionPeople().detect(solid(256, 256, r: 0.5, g: 0.5, b: 0.5))
        #expect(boxes.faces.isEmpty && boxes.bodies.isEmpty)
    }
}

/// Real ONNX sessions on blank frames (plumbing + fail-closed load path). Opt-in: needs the dev models.
@Suite(.enabled(if: RealDetectors.directory != nil, "set CSC_REAL_DETECTORS=1 with the dev detector models installed"))
struct RealDetectorPlumbingTests {
    @Test func sessionsRunOnBlankFrames() throws {
        let dir = try #require(RealDetectors.directory)
        let blank = solid(512, 512, r: 0.5, g: 0.5, b: 0.5)
        let freepik = try FreepikNudity(modelDirectory: dir, provider: .cpu)
        let levels = try freepik.levels(blank)
        #expect(levels.count == 4 && abs(levels.reduce(0, +) - 1) < 1e-6)
        #expect((0...1).contains(try freepik.nudityScore(blank)))
        let marqo = try MarqoNudity(modelDirectory: dir, provider: .cpu)
        #expect((0...1).contains(try marqo.nudityScore(blank)))
        let age = try MiVOLOAge(modelDirectory: dir, provider: .cpu)
        #expect(try age.age(face: nil, body: blank).isFinite)
        let bins = try SigLIPAgeBins(modelDirectory: dir)
        let p = try bins.forward(image: [Float](repeating: 0, count: 3 * 224 * 224))
        #expect(p.count == 5 && abs(p.reduce(0, +) - 1) < 1e-4)
        #expect((0...1).contains(try bins.youngProbability(blank)))
    }

    @Test func fullCheckLoadsAndAllowsBlank() async throws {
        let dir = try #require(RealDetectors.directory)
        let check = try ChildSafetyCheck(modelDirectory: dir, provider: .cpu)
        #expect(await RealDetectors.untimed(check).evaluate(image: solid(512, 512, r: 0.5, g: 0.5, b: 0.5)) == .allow)
    }

    @Test func manifestInitVerifiesRealHashes() async throws {
        let dir = try #require(RealDetectors.directory)
        var sha: [String: String] = [:]
        for (k, rel) in [(ModelManifest.nudityKey, FreepikNudity.relativePath), (ModelManifest.ageKey, MiVOLOAge.relativePath),
                         (ModelManifest.ageBinsKey, SigLIPAgeBins.relativePath), (ModelManifest.nudity2Key, MarqoNudity.relativePath)] {
            sha[k] = try #require(ModelManifest.sha256Hex(of: dir.appending(path: rel)))
        }
        let check = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: sha), provider: .cpu)
        #expect(check.thresholds == (try Thresholds.bundled()))
        #expect(check.detectors.nudity2 != nil)
        #expect(await RealDetectors.untimed(check).evaluate(image: solid(512, 512, r: 0.5, g: 0.5, b: 0.5)) == .allow)
    }

    @Test func wrongInputShapeFailsAtLoad() throws {
        let dir = try #require(RealDetectors.directory)
        #expect(throws: DetectorError.self) {
            _ = try OrtModel(path: dir.appending(path: MarqoNudity.relativePath), inputShape: [1, 3, 7], provider: .cpu)
        }
    }
}

enum RealDetectors {
    /// The same detectors without the per-image deadline: CPU-EP runs under a loaded parallel test host can
    /// exceed it, which (correctly) blocks; these tests check plumbing, not latency (that is NFR-F7's bench).
    static func untimed(_ c: ChildSafetyCheck) -> ChildSafetyCheck {
        var t = c.thresholds
        t.timeout = 600
        return ChildSafetyCheck(detectors: c.detectors, thresholds: t)
    }

    static let directory: URL? = {
        guard ProcessInfo.processInfo.environment["CSC_REAL_DETECTORS"] == "1" else { return nil }
        let base = ProcessInfo.processInfo.environment["ANTICHAT_DEV_CACHE"].map { "\($0)/Models" }
            ?? ("~/Library/Application Support/AntiChat-Dev/Models" as NSString).expandingTildeInPath
        let dir = URL(fileURLWithPath: base)
        let need = [FreepikNudity.relativePath, MarqoNudity.relativePath, MiVOLOAge.relativePath]
        return need.allSatisfy { FileManager.default.fileExists(atPath: dir.appending(path: $0).path) } ? dir : nil
    }()
}
