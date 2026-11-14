// M4.T03 (AT-285 AC1/AC6 runner-independent part): the gate driven directly, no runner. Fail closed when the detectors
// are absent or damaged; one trace record per preview / result / video; the forced-verdict seam is not compiled into
// test builds of Debug (ANTICHAT_UI_TESTING undefined). Content-free: blank canvases only (D-017).
import AntiChatEngineProtocol
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct MediaOutputGateTests {
    static func blank(_ side: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    static func frames(_ n: Int) -> AsyncThrowingStream<MediaFrame, Error> {
        AsyncThrowingStream { c in (0..<n).forEach { c.yield(MediaFrame(index: $0, image: blank(), isPreview: false)) }; c.finish() }
    }

    /// The trace counts are read from a task-scoped trace (`MediaOutputGate.scopedTrace`): the process-wide one is shared
    /// with the suites that run in parallel (VideoCheckStream, VideoGate*, VideoReviewFix check the gate too), so an
    /// exact count there raced. Every call is still recorded in the process-wide trace (the R-241 probe) as well.
    @Test func noManifestIsSafetyMissingForEveryCall() async {
        let scoped = MediaOutputGate.InvocationTrace()
        let global = MediaOutputGate.trace
        let before = (global.count(.preview), global.count(.result), global.count(.video))
        let gate = MediaOutputGate(manifestProvider: { nil })
        await MediaOutputGate.$scopedTrace.withValue(scoped) {
            #expect(await gate.checkPreview(Self.blank(), job: "j") == .safetyMissing(sizeBytes: 0))
            #expect(await gate.checkResult(Self.blank(), job: "j") == .safetyMissing(sizeBytes: 0))
            #expect(await gate.checkVideo(frames: Self.frames(3), frameCount: 3, fps: 16, job: "j") == .safetyMissing(sizeBytes: 0))
        }
        #expect(scoped.count(.preview) == 1 && scoped.count(.result) == 1)
        #expect(scoped.count(.video) == 1 && scoped.count == 3)
        // The same calls reached the process-wide trace (others may have added more meanwhile, never fewer).
        #expect(global.count(.preview) >= before.0 + 1 && global.count(.result) >= before.1 + 1)
        #expect(global.count(.video) >= before.2 + 1)
        #expect(await gate.calls == [.preview: 1, .result: 1, .video: 1])
        #expect(await !gate.isLoaded)
    }

    static func fakeInstall() throws -> (URL, SafetyManifest) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sha: [String: String] = [:]
        var paths: [String: String] = [:]
        for key in ["csc-nudity", "csc-age", "csc-age-bins"] {
            let url = dir.appending(path: "\(key).onnx")
            let data = Data("not a model \(key)".utf8)
            try data.write(to: url)
            sha[key] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            paths[key] = url.path
        }
        return (dir, SafetyManifest(nudityPath: paths["csc-nudity"]!, agePath: paths["csc-age"]!, ageBinsPath: paths["csc-age-bins"]!,
                                    sha256: sha, sizeBytes: 466_000_000))
    }

    @Test func missingFileIsSafetyMissingWithRepairSize() async throws {
        let (dir, m) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(atPath: m.agePath)
        let gate = MediaOutputGate(manifestProvider: { m })
        #expect(await gate.checkResult(Self.blank(), job: "j") == .safetyMissing(sizeBytes: 466_000_000))
    }

    @Test func damagedFileIsSafetyMissing() async throws {
        let (dir, m) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("flipped".utf8).write(to: URL(fileURLWithPath: m.nudityPath))
        let gate = MediaOutputGate(manifestProvider: { m })
        // A preview at the shipped valid size loads the detectors and fails closed on the damaged file.
        #expect(await gate.checkPreview(Self.blank(MediaOutputGate.previewMinSide), job: "j") == .safetyMissing(sizeBytes: 466_000_000))
        // Hashes right but the files are not models ⇒ still fail closed (load error).
        let (dir2, m2) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir2) }
        #expect(await MediaOutputGate(manifestProvider: { m2 }).checkResult(Self.blank(), job: "j") == .safetyMissing(sizeBytes: 466_000_000))
    }

    /// fix/t05-video (NFR-F7): a preview below the shipped valid size is withheld without loading the detectors (the
    /// check would withhold it without running anything anyway); nothing installed still fails closed; the final check
    /// of a damaged install still fails closed (the preview never vouched for anything).
    @Test func previewBelowTheValidSizeIsWithheldWithoutLoadingTheDetectors() async throws {
        let small = MediaOutputGate.previewMinSide - 1
        #expect(!MediaOutputGate.previewSizeShowable(width: small, height: 4 * small))
        #expect(MediaOutputGate.previewSizeShowable(width: MediaOutputGate.previewMinSide, height: MediaOutputGate.previewMinSide))
        let (dir, m) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("flipped".utf8).write(to: URL(fileURLWithPath: m.nudityPath))
        let gate = MediaOutputGate(manifestProvider: { m })
        #expect(await gate.checkPreview(Self.blank(small), job: "j") == .withhold)
        #expect(await !gate.isLoaded, "no detector load for a preview that can never be shown")
        #expect(await gate.lastLoadSeconds == nil)
        #expect(await gate.calls[.preview] == 1, "still one counted gate call (R-241 trace)")
        #expect(await gate.checkResult(Self.blank(small), job: "j") == .safetyMissing(sizeBytes: 466_000_000))
        #expect(await MediaOutputGate(manifestProvider: { nil }).checkPreview(Self.blank(small), job: "j") == .safetyMissing(sizeBytes: 0))
    }

    @Test func forcedVerdictSeamIsNotCompiledHere() {
        #if ANTICHAT_UI_TESTING
        Issue.record("ANTICHAT_UI_TESTING must not be defined in Debug/Release test builds (R-285 AC6)")
        #endif
    }

    /// Opt-in (CSC_REAL_DETECTORS=1 + dev models): the production load path allows a blank canvas, then releases.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CSC_REAL_DETECTORS"] == "1"))
    func realDetectorsAllowBlankAndRelease() async throws {
        let base = URL(fileURLWithPath: ("~/Library/Application Support/AntiChat-Dev/Models" as NSString).expandingTildeInPath)
        let nud = base.appending(path: "csc-nudity/onnx/model.onnx"), age = base.appending(path: "csc-age/mivolo_v2_age.onnx")
        let bins = base.appending(path: "csc-age-bins/model.safetensors")
        func sha(_ u: URL) throws -> String {
            SHA256.hash(data: try Data(contentsOf: u, options: .alwaysMapped)).map { String(format: "%02x", $0) }.joined()
        }
        let m = SafetyManifest(nudityPath: nud.path, agePath: age.path, ageBinsPath: bins.path,
                               sha256: ["csc-nudity": try sha(nud), "csc-age": try sha(age), "csc-age-bins": try sha(bins)],
                               sizeBytes: 0)
        let gate = MediaOutputGate(manifestProvider: { m })
        #expect(await gate.checkResult(Self.blank(512), job: "j") == .allow)
        #expect(await gate.isLoaded)
        await gate.release()
        #expect(await !gate.isLoaded)
    }
}
