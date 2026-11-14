// M5.T03 (DEBUG / test only): the scripted video engine — the test double of VideoEngine with no runtime and no model.
// It reports scripted stages and steps, hands an animated gradient preview per step to `outputs.preview` and the final
// gradient frames (RGBA8, the requested size) to `outputs.videoResult`, exactly the calls VideoEngine makes, so every
// output still goes through the MediaJobRunner's gate. It never writes anything and never decides blocking.
// Script: `ScriptedVideoScript` (`-UseScriptedVideoEngine <script.json>` → `VideoRequest.generator`).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScriptedVideoEngine {
    public static func isScripted(_ req: VideoRequest) -> Bool { ScriptedVideoScript.parse(generator: req.generator) != nil }

    public static func run(_ req: VideoRequest, isCancelled: @escaping @Sendable () -> Bool, outputs: MediaJobOutputs,
                           emit: @escaping VideoEngine.Emit, governor: VideoJobGovernor? = nil) async throws -> MediaJobRunner.EngineEnd {
        let s = ScriptedVideoScript.parse(generator: req.generator) ?? ScriptedVideoScript()
        await governor?.attach(NoChildPauseTarget())
        let t0 = ContinuousClock.now
        func now() -> Double { VideoChild.secs(ContinuousClock.now - t0) }
        await emit(.videoProgress(VideoProgress(stage: "encode", step: 1, totalSteps: 1, t: now(), childPID: 0)))
        let (pw, ph) = previewSize(req.width, req.height)
        for step in 1...max(1, s.steps) {
            if isCancelled() { return .cancelled }
            try? await Task.sleep(for: .milliseconds(s.delayMs))
            if isCancelled() { return .cancelled }
            await emit(.videoProgress(VideoProgress(stage: "denoise", step: step, totalSteps: s.steps, t: now(), childPID: 0)))
            guard await outputs.progress(step: step, totalSteps: s.steps) else { return .completed }
            for f in 0..<s.previewFrames where VideoPreviewPolicy.shows(step: step, of: s.steps) {
                let jpeg = gradientJPEG(width: pw, height: ph, phase: step * 16 + f * 4)
                guard await outputs.preview(jpeg, step: step, totalSteps: s.steps, frame: f) else { return .completed }
            }
            await governor?.checkpoint(step: step, total: s.steps, isCancelled: isCancelled)  // M5.T11 step boundary
        }
        await governor?.leftDenoise()
        if isCancelled() { return .cancelled }
        let frames = (0..<s.frames).map { gradientRGBA(width: req.width, height: req.height, phase: $0 * 4) }
        await emit(.videoProgress(VideoProgress(stage: "decode", step: s.frames, totalSteps: s.frames, t: now(), childPID: 0)))
        let audio: Data? = s.audio ? Data(count: Int(Double(s.frames) / Double(s.fps) * 48_000) * 8) : nil
        _ = try await outputs.videoResult(frames: frames, width: req.width, height: req.height, fps: Double(s.fps), audio: audio,
                                          info: VideoEngine.info(req, steps: s.steps))
        return .completed
    }

    static func previewSize(_ w: Int, _ h: Int) -> (Int, Int) {
        let short = 160
        if min(w, h) <= short { return (w, h) }
        return w <= h ? (short, max(short, Int((Double(h) * Double(short) / Double(w)).rounded())))
                      : (max(short, Int((Double(w) * Double(short) / Double(h)).rounded())), short)
    }

    static func gradientRGBA(width: Int, height: Int, phase: Int) -> Data {
        var d = Data(count: width * height * 4)
        d.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            let b = p.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    b[i] = UInt8((x * 255 / max(1, width - 1) + phase) & 0xFF)
                    b[i + 1] = UInt8((y * 255 / max(1, height - 1) + phase) & 0xFF)
                    b[i + 2] = 128
                    b[i + 3] = 255
                }
            }
        }
        return d
    }

    static func gradientJPEG(width: Int, height: Int, phase: Int) -> Data {
        let rgba = gradientRGBA(width: width, height: height, phase: phase)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: rgba as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
#endif
