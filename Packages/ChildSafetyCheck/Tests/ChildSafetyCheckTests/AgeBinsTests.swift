// SigLIPAgeBins safetensors index (fail closed on a different file) and the forward on a synthetic, content-free
// model: the real weights are only loaded by the opt-in plumbing test (CSC_REAL_DETECTORS=1).
import Foundation
import Testing
@testable import ChildSafetyCheck

@Suite struct AgeBinsTests {
    /// Writes a safetensors file holding `tensors` (name → (shape, value)), all F32 filled with `value`.
    static func write(_ tensors: [String: ([Int], Float)], to url: URL) throws {
        var header: [String: Any] = [:]
        var blob = Data()
        for (name, (shape, value)) in tensors.sorted(by: { $0.key < $1.key }) {
            let n = shape.reduce(1, *)
            header[name] = ["dtype": "F32", "shape": shape, "data_offsets": [blob.count, blob.count + n * 4]]
            blob.append([Float](repeating: value, count: n).withUnsafeBytes { Data($0) })
        }
        var h = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        while (8 + h.count) % 8 != 0 { h.append(0x20) }
        var len = UInt64(h.count).littleEndian
        var file = Data(bytes: &len, count: 8)
        file.append(h)
        file.append(blob)
        try file.write(to: url)
    }

    static func synthetic(_ override: [String: ([Int], Float)] = [:]) -> [String: ([Int], Float)] {
        var t = SigLIPAgeBins.expectedShapes().mapValues { ($0, Float(0)) }
        // LayerNorm gains 1 so activations stay finite; everything else 0 ⇒ logits = classifier bias.
        for k in t.keys where k.hasSuffix("layer_norm1.weight") || k.hasSuffix("layer_norm2.weight")
            || k == "vision_model.post_layernorm.weight" { t[k]!.1 = 1 }
        for (k, v) in override { t[k] = v }
        return t
    }

    func tmp() -> URL { FileManager.default.temporaryDirectory.appending(path: "csc-bins-\(UUID().uuidString).safetensors") }

    @Test func syntheticModelGivesSoftmaxOfClassifierBias() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(Self.synthetic(), to: url)
        let m = try SigLIPAgeBins(path: url)
        let p = try m.forward(image: [Float](repeating: 0.3, count: 3 * 224 * 224))
        #expect(p.count == 5)
        for v in p { #expect(abs(v - 0.2) < 1e-5) }  // equal (zero) bias ⇒ uniform bins
        #expect(abs(try m.youngProbability(blankImage()) - 0.4) < 1e-5)
    }

    /// A-M9-T05-F7: the one-call path (parallel preprocessing, forwards one at a time) answers exactly what the single
    /// calls answer, in order; the forwards hold the accelerate engine lock, never two at once.
    @Test func oneCallForEveryBodyEqualsSingleCalls() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(Self.synthetic(["classifier.bias": ([5], 0.5)]), to: url)
        let m = try SigLIPAgeBins(path: url)
        let crops = [blankImage(), blankImage(40), blankImage(90)]
        let single = try crops.map { try m.youngProbability($0) }
        #expect(try m.youngProbabilities(crops).map(\.bitPattern) == single.map(\.bitPattern))
        #expect(try m.youngProbabilities([]) == [])
    }

    @Test func wrongShapeDtypeOrTruncationFailsAtLoad() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(Self.synthetic(["classifier.weight": ([4, 768], 0)]), to: url)
        #expect(throws: DetectorError.self) { _ = try SigLIPAgeBins(path: url) }
        var missing = Self.synthetic()
        missing["vision_model.encoder.layers.11.mlp.fc2.bias"] = nil
        try Self.write(missing, to: url)
        #expect(throws: DetectorError.self) { _ = try SigLIPAgeBins(path: url) }
        try Self.write(Self.synthetic(), to: url)
        let d = try Data(contentsOf: url)
        try d.prefix(d.count - 4).write(to: url)
        #expect(throws: DetectorError.self) { _ = try SigLIPAgeBins(path: url) }
        try Data("not safetensors".utf8).write(to: url)
        #expect(throws: DetectorError.self) { _ = try SigLIPAgeBins(path: url) }
        #expect(throws: DetectorError.self) { _ = try SigLIPAgeBins(path: url.appending(path: "absent")) }
    }

    @Test func nonFiniteWeightsFailAtLoad() throws {
        let url = tmp()
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.write(Self.synthetic(["classifier.bias": ([5], .nan)]), to: url)
        #expect(throws: DetectorError.self) { _ = try SigLIPAgeBins(path: url) }
    }
}
