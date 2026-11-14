// Nudity scorers (model-matrix §10.1). Off-the-shelf catalog entries, used as published (D-006, D-007).
import CoreGraphics
import Foundation

package protocol NudityScoring: Sendable {
    /// A nudity score in [0, 1]; meaning depends on the model (see conformers).
    func nudityScore(_ image: CGImage) throws -> Double
}

/// Freepik/nsfw_image_detector (EVA02-base 448, 4 levels neutral/low/medium/high), ONNX port
/// sitatech/freepik_nsfw_detector_onnx@250a860 `onnx/model.onnx` (fp32; the fp16 file of the same commit
/// runs ~2× slower on the CoreML EP and crashes ORT's extended fusions, S-8 report).
/// Preprocessing from the pinned timm `config.json`: squash, bicubic, CLIP mean/std.
/// Score = P(medium) + P(high).
package final class FreepikNudity: NudityScoring, @unchecked Sendable {
    package static let relativePath = "csc-nudity/onnx/model.onnx"
    static let side = 448
    static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    static let std: [Float] = [0.26862954, 0.26130258, 0.27577711]
    let model: OrtModel

    package convenience init(modelDirectory: URL, provider: ExecutionProvider, cacheDirectory: URL? = nil,
                             file: String = relativePath) throws {
        try self.init(path: modelDirectory.appending(path: file), provider: provider, cacheDirectory: cacheDirectory)
    }

    package init(path: URL, provider: ExecutionProvider, cacheDirectory: URL? = nil) throws {
        model = try OrtModel(path: path, inputShape: [1, 3, Self.side, Self.side], provider: provider,
                             cacheDirectory: cacheDirectory)
    }

    /// The four level probabilities [neutral, low, medium, high].
    package func levels(_ image: CGImage) throws -> [Double] {
        let x = try ImageTensor.chw(image, side: Self.side, mode: .squash, mean: Self.mean, std: Self.std)
        let logits = try model.run(x)
        guard logits.count == 4 else { throw DetectorError.inference("freepik: \(logits.count) outputs") }
        return softmax(logits)
    }

    package func nudityScore(_ image: CGImage) throws -> Double {
        let p = try levels(image)
        return p[2] + p[3]
    }
}

/// Marqo/nsfw-image-detection-384 (ViT-tiny 384, binary), ONNX ICIJ/nsfw-image-detection-384-onnx@4f63fac.
/// Resize 384², mean/std 0.5. Labels ["NSFW", "SFW"]; score = P(NSFW).
package final class MarqoNudity: NudityScoring, @unchecked Sendable {
    package static let relativePath = "csc-nudity2/marqo-nsfw-384.onnx"
    static let side = 384
    let model: OrtModel

    package convenience init(modelDirectory: URL, provider: ExecutionProvider, cacheDirectory: URL? = nil) throws {
        try self.init(path: modelDirectory.appending(path: Self.relativePath), provider: provider,
                      cacheDirectory: cacheDirectory)
    }

    package init(path: URL, provider: ExecutionProvider, cacheDirectory: URL? = nil) throws {
        model = try OrtModel(path: path, inputShape: [1, 3, Self.side, Self.side], provider: provider,
                             cacheDirectory: cacheDirectory)
    }

    package func nudityScore(_ image: CGImage) throws -> Double {
        let x = try ImageTensor.chw(image, side: Self.side, mode: .squash, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5])
        let logits = try model.run(x)
        guard logits.count == 2 else { throw DetectorError.inference("marqo: \(logits.count) outputs") }
        return softmax(logits)[0]
    }
}
