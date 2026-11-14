// Apparent-age regressor (model-matrix §10.2): MiVOLO v2, ONNX Sam-Apostel/mivolo-v2-age-onnx@8eb4cd8.
import CoreGraphics
import Foundation

/// One age query's crops: a face and its matched body; nil = MiVOLO's black "no crop".
package struct AgeInput: @unchecked Sendable {
    package var face: CGImage?
    package var body: CGImage?
    package init(face: CGImage?, body: CGImage?) {
        self.face = face
        self.body = body
    }
}

package protocol AgeEstimating: Sendable {
    /// Estimated age in years from a face crop and a body crop; a nil crop is MiVOLO's black "no crop".
    func age(face: CGImage?, body: CGImage?) throws -> Double
    /// Every age query of one image in ONE call, results in input order (F7 tail, A-M9-T05-F7). Same model, same
    /// estimate per input as `age(face:body:)`; an implementation may prepare the inputs together but runs the model
    /// one input at a time (no two model runs overlap). Any error fails the whole call.
    func ages(_ inputs: [AgeInput]) throws -> [Double]
}

extension AgeEstimating {
    package func ages(_ inputs: [AgeInput]) throws -> [Double] {
        try inputs.map { try age(face: $0.face, body: $0.body) }
    }
}

/// Input `faces_bodies` float32 [1, 6, 384, 384]: face RGB then body RGB, each letterboxed to 384²
/// (black pad, centred), /255, ImageNet mean/std (model card; MiVOLO `prepare_classification_images`).
/// Output `age` float32 [1, 1] in years.
/// The published graph's input is fixed at batch 1 (`faces_bodies` [1, 6, 384, 384], no symbolic dimension; its
/// Reshape/Col2Im nodes are exported for batch 1), so several queries cannot share one model run without converting
/// the model, which D-007 rules out: `ages` prepares every tensor in parallel on the CPU, then runs the model once
/// per query, back to back.
package final class MiVOLOAge: AgeEstimating, @unchecked Sendable {
    package static let relativePath = "csc-age/mivolo_v2_age.onnx"
    static let side = 384
    static let mean: [Float] = [0.485, 0.456, 0.406]
    static let std: [Float] = [0.229, 0.224, 0.225]
    let model: OrtModel

    package convenience init(modelDirectory: URL, provider: ExecutionProvider, cacheDirectory: URL? = nil) throws {
        try self.init(path: modelDirectory.appending(path: Self.relativePath), provider: provider,
                      cacheDirectory: cacheDirectory)
    }

    package init(path: URL, provider: ExecutionProvider, cacheDirectory: URL? = nil) throws {
        model = try OrtModel(path: path, inputShape: [1, 6, Self.side, Self.side], provider: provider,
                             cacheDirectory: cacheDirectory)
    }

    package func age(face: CGImage?, body: CGImage?) throws -> Double {
        try estimate(Self.tensor(AgeInput(face: face, body: body)))
    }

    package func ages(_ inputs: [AgeInput]) throws -> [Double] {
        // CPU only (crop rendering + normalisation), all queries at once; the model runs below stay serial.
        let tensors = try ImageTensor.concurrentMap(inputs) { try Self.tensor($0) }
        return try tensors.map { try estimate($0) }
    }

    /// The model input for one query: face planes then body planes (6 × 384²).
    static func tensor(_ input: AgeInput) throws -> [Float] {
        var x = try ImageTensor.chw(input.face, side: side, mode: .letterbox, mean: mean, std: std)
        x += try ImageTensor.chw(input.body, side: side, mode: .letterbox, mean: mean, std: std)
        return x
    }

    private func estimate(_ x: [Float]) throws -> Double {
        let out = try model.run(x)
        guard let a = out.first, a.isFinite else { throw DetectorError.inference("mivolo: no age") }
        return Double(a)
    }
}
