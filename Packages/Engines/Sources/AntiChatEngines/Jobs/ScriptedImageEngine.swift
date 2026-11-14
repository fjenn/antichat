// M2.T13 (RL-006): the scripted image engine. DEBUG / test only, and the ONE copy (M4.T04 extends this type).
// The step-aside choreography runs against a real memory load without diffusion weights: a job allocates its
// declared footprint as shared-storage MTLBuffers (touched, so they count in `phys_footprint` and
// `MTLDevice.currentAllocatedSize` like sd-server's context), reports scripted per-step progress, writes a 1×1 PNG
// and frees everything when the job ends (NFR-R4: nothing stays resident after a job on T0–T2).
// An ImageModelSet whose `diffusionModel` is `scripted:<steps>:<ms per step>[:<crashAtStep>[:<slowCancelMs>]]` routes
// here instead of sd-server (`ScriptedImageScript` builds it from `-UseScriptedImageEngine <script.json>`).
// M4.T04 step 7: each step hands a gradient preview at the target aspect (none with `preview: none`) to the job's
// `MediaJobOutputs`, the final
// output is a gradient PNG at the requested size (≥ 64 px a side); the engine never writes them itself — the
// runner's gate does, after its check. It never decides blocking. `crashAtStep` aborts the helper at that step
// (helper-crash → `lost` tests); `slowCancelMs` delays the stop after a cancel (the slow-engine cancel path).
// `toolSchemas` are the stub `create_image` / `create_video` tools M2.T23/T24 offer before M4/M5 exist.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Metal

public final class ScriptedImageEngine: @unchecked Sendable {
    public static let scheme = "scripted:"
    public static let chunk = 256 * 1024 * 1024

    public static func isScripted(_ set: ImageModelSet) -> Bool { set.diffusionModel.hasPrefix(scheme) }

    public struct Script: Sendable, Equatable {
        public var steps = 4
        public var msPerStep = 50
        /// 0 = never.
        public var crashAtStep = 0
        public var slowCancelMs = 0
    }

    /// `scripted:<steps>:<ms>[:<crashAtStep>[:<slowCancelMs>]]`; defaults 4 × 50 ms, no crash, immediate cancel.
    public static func script(_ set: ImageModelSet) -> Script {
        let p = set.diffusionModel.dropFirst(scheme.count).split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        var s = Script()
        if let v = p.first ?? nil { s.steps = v }
        if p.count > 1, let v = p[1] { s.msPerStep = v }
        if p.count > 2, let v = p[2] { s.crashAtStep = v }
        if p.count > 3, let v = p[3] { s.slowCancelMs = v }
        return s
    }

    /// A model set for tests: `footprint` bytes, `steps` steps of `ms` each.
    public static func modelSet(key: String = "scripted-image", footprint: UInt64, steps: Int = 4, ms: Int = 50,
                                crashAtStep: Int = 0, slowCancelMs: Int = 0) -> ImageModelSet {
        ScriptedImageScript(steps: steps, delayMs: ms, crashAtStep: crashAtStep, slowCancelMs: slowCancelMs,
                            footprintBytes: footprint).modelSet(key: key)
    }

    public static let toolSchemas: [ToolSchema] = [
        ToolSchema(name: "create_image", description: "Create a picture from a text description.",
                   parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string"},"size":{"type":"string","enum":["square","portrait","landscape"]}},"required":["prompt"]}"#),
        ToolSchema(name: "create_video", description: "Create a short video clip from a text description.",
                   parametersJSON: #"{"type":"object","properties":{"prompt":{"type":"string"},"seconds":{"type":"integer"}},"required":["prompt"]}"#),
    ]

    private let lock = NSLock()
    private var buffers: [MTLBuffer] = []
    public var allocatedBytes: UInt64 { lock.withLock { buffers.reduce(0) { $0 + UInt64($1.length) } } }

    public init() {}

    /// Allocates `bytes` as touched shared MTLBuffers (the job's context).
    public func allocate(_ bytes: UInt64) throws {
        guard let dev = MTLCreateSystemDefaultDevice() else { throw AntiChatError.engine("noMetal", "scripted image") }
        var left = Int(bytes)
        var out: [MTLBuffer] = []
        while left > 0 {
            let n = min(left, Self.chunk)
            guard let b = dev.makeBuffer(length: n, options: .storageModeShared) else {
                throw AntiChatError(domain: .model, code: "notEnoughMemory", userMessageKey: "model.notEnoughMemory", detail: "MTLBuffer \(n)")
            }
            memset(b.contents(), 1, n)
            out.append(b)
            left -= n
        }
        lock.withLock { buffers = out }
    }

    public func free() { lock.withLock { buffers.removeAll() } }

    /// One scripted job. `stop` asks the caller's cancel flag to stop (a withheld preview); `outputs` = the runner.
    public func run(_ req: ImageRequest, thermal: ThermalPolicy.State = .nominal, isCancelled: @Sendable () -> Bool,
                    stop: @Sendable () -> Void = {}, outputs: MediaJobOutputs,
                    emit: @escaping @Sendable (MediaEvent) async -> Void) async throws -> ImageResult {
        let script = Self.script(req.model)
        let steps = max(1, script.steps), ms = script.msPerStep
        try allocate(req.model.footprintBytes)
        defer { free() }
        let previewSize = Self.fit(width: req.width, height: req.height, longSide: 64)
        var status = "completed"
        for s in 1...steps {
            if isCancelled() || Task.isCancelled { status = "cancelled"; break }
            try? await Task.sleep(for: .milliseconds(ms))
            if script.crashAtStep > 0, s == script.crashAtStep {
                AppLog.log(.engine, .error, "ScriptedImageEngine: crashAtStep \(s) → abort()")
                abort()
            }
            // NFR-B3: at `.serious` a heavy job sleeps between steps (ThermalPolicy pacing).
            let pause = ThermalPolicy.pauseAfterStep(Double(ms) / 1000, thermal)
            if pause > 0 { try? await Task.sleep(for: .milliseconds(Int(pause * 1000))) }
            // `preview: none` (like sd-server's): progress only, nothing to check; otherwise one gated preview per step.
            let preview = req.preview == "none" ? Data()
                : Self.gradientPNG(width: previewSize.0, height: previewSize.1, phase: Double(s) / Double(steps))
            let goOn = preview.isEmpty ? await outputs.progress(step: s, totalSteps: steps)
                                       : await outputs.preview(preview, step: s, totalSteps: steps)
            if !goOn { stop() }
            await emit(.imageProgress(ImageProgress(pass: 1, step: s, totalSteps: steps, previewBytes: preview.count,
                                                    previewSHA256: Self.sha256(preview).prefix(16).description, sdServerPID: 0)))
        }
        if status == "cancelled", script.slowCancelMs > 0 { try? await Task.sleep(for: .milliseconds(script.slowCancelMs)) }
        let metrics: [String: Double] = ["scripted_footprint": Double(req.model.footprintBytes), "steps": Double(steps)]
        if let w = await outputs.withheld { return ImageResult(status: w.status, path: "", width: 0, height: 0, sha256: "", bytes: 0, metrics: metrics) }
        guard status == "completed" else { return ImageResult(status: status, path: "", width: 0, height: 0, sha256: "", bytes: 0, metrics: metrics) }
        // No live previews (T0–T2): the context leaves memory before the final check, as sd-server does (NFR-R1).
        if req.preview == "none" { free() }
        let size = Self.fit(width: req.width, height: req.height, minSide: 64)
        let png = Self.gradientPNG(width: size.0, height: size.1, phase: 1)
        guard let path = await outputs.result(png, metadata: ["width": "\(size.0)", "height": "\(size.1)", "seed": "\(req.seed)", "engine": "scripted"]) else {
            let w = await outputs.withheld
            return ImageResult(status: w?.status ?? "failed", path: "", width: 0, height: 0, sha256: "", bytes: 0, metrics: metrics)
        }
        return ImageResult(status: "completed", path: path, width: size.0, height: size.1, sha256: Self.sha256(png), bytes: png.count, metrics: metrics)
    }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// `width`×`height` scaled so the long side is `longSide`, or so the short side is at least `minSide`
    /// (capped at 2048 a side); always ≥ 1.
    static func fit(width: Int, height: Int, longSide: Int? = nil, minSide: Int? = nil) -> (Int, Int) {
        let w = Double(max(1, width)), h = Double(max(1, height))
        var k = 1.0
        if let l = longSide { k = Double(l) / max(w, h) }
        if let m = minSide, min(w, h) < Double(m) { k = Double(m) / min(w, h) }
        k = min(k, 2048 / max(w, h))
        return (max(1, Int((w * k).rounded())), max(1, Int((h * k).rounded())))
    }

    /// A content-free diagonal gradient (blue → orange, shifted by `phase`), PNG-encoded.
    static func gradientPNG(width: Int, height: Int, phase: Double) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let p = CGFloat(min(1, max(0, phase)))
        let colors = [CGColor(red: 0.2, green: 0.35 + 0.3 * p, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.6, blue: 0.2 + 0.3 * p, alpha: 1)]
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
#endif
