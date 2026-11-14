// M4.T15 step 6 (R-034, R-285 AC1, D-006): the editor operations the helper runs itself — a `local` media job
// (`MediaJobKind.local`, `ImageRequest.localOperation`). They are Photo outputs, so like every generated picture their
// one result goes ONLY through `MediaJobOutputs.result` → `MediaJobRunner.emitResult` → `MediaOutputGate.checkResult`
// (one gate call per final; no previews). Nothing here writes a picture to disk itself.
//   * `removeBackground`: Vision foreground mask → RGBA PNG with alpha (ForegroundMask). No subject → `noSubject`.
//   * `erase`: LaMa (`img-erase`, Core ML) on the masked region + MaskCompositor (outside the dilated mask = source).
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import Foundation

public enum LocalImageJob {
    public static let removeBackground = "removeBackground"
    public static let erase = "erase"

    /// Runs `req` (a local job) and hands its one result to the gate. `eraser` = the loaded `img-erase` (nil = missing).
    public static func run(_ req: ImageRequest, outputs: MediaJobOutputs, eraser: @Sendable (String) async -> LaMaEraser?,
                           isCancelled: @Sendable () -> Bool) async throws -> MediaJobRunner.EngineEnd {
        guard let srcPath = req.initImagePath, let srcData = FileManager.default.contents(atPath: srcPath),
              let source = MaskCompositor.decode(srcData) else { throw mediaError("localNoSource") }
        guard await outputs.progress(step: 0, totalSteps: 1) else { return .cancelled }
        let t0 = ContinuousClock.now
        let png: Data
        switch req.localOperation {
        case removeBackground?:
            guard let mask = try ForegroundMask.mask(for: source) else { throw mediaError("noSubject") }
            guard let cut = ForegroundMask.cutout(source, mask: mask), let data = MaskCompositor.png(cut) else {
                throw mediaError("localEncode")
            }
            png = data
        case erase?:
            guard let maskPath = req.maskImagePath, let maskData = FileManager.default.contents(atPath: maskPath),
                  let mask = MaskCompositor.decode(maskData) else { throw mediaError("localNoMask") }
            guard let lama = await eraser(req.model.diffusionModel) else { throw mediaError("eraseModelMissing") }
            let out = try await lama.erase(source: source, mask: mask)
            guard let data = MaskCompositor.png(out) else { throw mediaError("localEncode") }
            png = data
        default:
            throw mediaError("localUnknownOperation", req.localOperation)
        }
        if isCancelled() { return .cancelled }
        let d = ContinuousClock.now - t0
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        _ = await outputs.result(png, metadata: ["width": "\(source.width)", "height": "\(source.height)",
                                                 "operation": req.localOperation ?? "", "engine_s": String(format: "%.3f", seconds)])
        return .completed
    }
}
