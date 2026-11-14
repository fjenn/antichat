// Age-bin classifier, the body-only second age signal (model-matrix §10.2/§10.3 "SigLIP2 age bins"; A-M4-T02b):
// prithivMLmods/Age-Classification-SigLIP2@b41e62c `model.safetensors` (Apache-2.0, fp32, 371.6 MB), used as
// published. The pin has no ONNX file and D-007 forbids publishing a conversion, so the vision tower runs here
// directly from the pinned safetensors with Accelerate (BLAS), no conversion step: `SiglipForImageClassification`
// = SigLIP base/16 vision transformer at 224² → post-LayerNorm → mean over the 196 tokens → linear, 5 bins
// [Child 0–12, Teenager 13–20, Adult 21–44, Middle Age 45–64, Aged 65+]. It can only add blocks: it is consulted
// for people without a usable face, where MiVOLO's body-only estimate is too loose (S-8 report).
import Accelerate
import CoreGraphics
import Foundation

package protocol AgeBinScoring: Sendable {
    /// P(Child 0–12) + P(Teenager 13–20) for one person crop, in [0, 1].
    func youngProbability(_ image: CGImage) throws -> Double
    /// The same for every body-only crop of one image in ONE call, in input order (F7 tail, A-M9-T05-F7); one forward
    /// per crop, never two at once. Any error fails the whole call.
    func youngProbabilities(_ images: [CGImage]) throws -> [Double]
}

extension AgeBinScoring {
    package func youngProbabilities(_ images: [CGImage]) throws -> [Double] {
        try images.map { try youngProbability($0) }
    }
}

/// A CGImage handed to the CPU preprocessing workers (CGImage is immutable and thread-safe).
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

package final class SigLIPAgeBins: AgeBinScoring, @unchecked Sendable {
    package static let relativePath = "csc-age-bins/model.safetensors"
    static let side = 224, patch = 16, grid = 14, tokens = 196, width = 768, heads = 12, headDim = 64
    static let mlp = 3072, layers = 12, bins = 5, eps: Float = 1e-6

    /// Keeps the mapped file alive; every weight pointer below points into it (read-only, so concurrent
    /// `youngProbability` calls are safe: each call allocates its own activations).
    private let file: NSData
    private let w: [String: UnsafePointer<Float>]

    package init(path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw DetectorError.modelMissing(path.lastPathComponent)
        }
        do {
            file = try NSData(contentsOf: path, options: .alwaysMapped)
        } catch {
            throw DetectorError.modelLoad("\(path.lastPathComponent): unreadable")
        }
        w = try Self.index(file, expected: Self.expectedShapes())
        // Warm-up run: proves the weights produce finite probabilities (fail closed at load, not at first use).
        let p = try forward(image: [Float](repeating: 0, count: 3 * Self.side * Self.side))
        guard p.allSatisfy(\.isFinite) else { throw DetectorError.modelLoad("age bins: non-finite output") }
    }

    package convenience init(modelDirectory: URL) throws {
        try self.init(path: modelDirectory.appending(path: Self.relativePath))
    }

    package func youngProbability(_ image: CGImage) throws -> Double {
        try young(forward(image: Self.tensor(image)))
    }

    package func youngProbabilities(_ images: [CGImage]) throws -> [Double] {
        // CPU preprocessing of every crop at once; the forwards stay one at a time (`InferenceLock.accelerate`).
        let tensors = try ImageTensor.concurrentMap(images.map(SendableImage.init)) { try Self.tensor($0.image) }
        return try tensors.map { try young(forward(image: $0)) }
    }

    /// SiglipImageProcessor: resize to 224² (squash), /255, mean = std = 0.5.
    static func tensor(_ image: CGImage) throws -> [Float] {
        try ImageTensor.chw(image, side: side, mode: .squash, mean: [0.5, 0.5, 0.5], std: [0.5, 0.5, 0.5])
    }

    private func young(_ p: [Float]) throws -> Double {
        let young = Double(p[0] + p[1])
        guard young.isFinite else { throw DetectorError.inference("age bins: non-finite") }
        return min(1, max(0, young))
    }

    /// The five bin probabilities for a CHW 3×224×224 tensor. Holds the `accelerate` engine lock: no two age-bin
    /// forwards ever overlap; one may run beside an ONNX Runtime run of the same evaluation (InferenceLock).
    package func forward(image x: [Float]) throws -> [Float] {
        try InferenceLock.accelerate.run { try forwardUnlocked(image: x) }
    }

    private func forwardUnlocked(image x: [Float]) throws -> [Float] {
        let T = Self.tokens, D = Self.width, P = Self.patch, G = Self.grid, S = Self.side
        // Patch embedding (Conv2d 3→768, k = s = 16) as im2col · Wᵀ; column order (c, ky, kx) = the weight layout.
        guard x.count == 3 * S * S else { throw DetectorError.preprocessing }
        var cols = [Float](repeating: 0, count: T * 3 * P * P)
        x.withUnsafeBufferPointer { xp in cols.withUnsafeMutableBufferPointer { cp in
            for gy in 0..<G {
                for gx in 0..<G {
                    let row = (gy * G + gx) * 3 * P * P
                    for c in 0..<3 {
                        for ky in 0..<P {
                            let src = c * S * S + (gy * P + ky) * S + gx * P
                            (cp.baseAddress! + row + (c * P + ky) * P).update(from: xp.baseAddress! + src, count: P)
                        }
                    }
                }
            }
        } }
        var h = [Float](repeating: 0, count: T * D)
        linear(cols, rows: T, inDim: 3 * P * P, "vision_model.embeddings.patch_embedding", outDim: D, into: &h)
        addInPlace(&h, w["vision_model.embeddings.position_embedding.weight"]!)

        var n = [Float](repeating: 0, count: T * D)
        var q = n, k = n, v = n, o = n, tmp = n
        var mid = [Float](repeating: 0, count: T * Self.mlp)
        var scores = [Float](repeating: 0, count: T * T)
        let scale = 1 / Float(Self.headDim).squareRoot()
        for l in 0..<Self.layers {
            let p = "vision_model.encoder.layers.\(l)."
            layerNorm(h, rows: T, p + "layer_norm1", into: &n)
            linear(n, rows: T, inDim: D, p + "self_attn.q_proj", outDim: D, into: &q)
            linear(n, rows: T, inDim: D, p + "self_attn.k_proj", outDim: D, into: &k)
            linear(n, rows: T, inDim: D, p + "self_attn.v_proj", outDim: D, into: &v)
            for hd in 0..<Self.heads {
                let off = hd * Self.headDim
                q.withUnsafeBufferPointer { qp in k.withUnsafeBufferPointer { kp in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(T), Int32(T), Int32(Self.headDim), scale,
                                qp.baseAddress! + off, Int32(D), kp.baseAddress! + off, Int32(D), 0, &scores, Int32(T))
                } }
                softmaxRows(&scores, rows: T, cols: T)
                v.withUnsafeBufferPointer { vp in o.withUnsafeMutableBufferPointer { op in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(T), Int32(Self.headDim), Int32(T), 1,
                                scores, Int32(T), vp.baseAddress! + off, Int32(D), 0, op.baseAddress! + off, Int32(D))
                } }
            }
            linear(o, rows: T, inDim: D, p + "self_attn.out_proj", outDim: D, into: &tmp)
            tmp.withUnsafeBufferPointer { addInPlace(&h, $0.baseAddress!) }
            layerNorm(h, rows: T, p + "layer_norm2", into: &n)
            linear(n, rows: T, inDim: D, p + "mlp.fc1", outDim: Self.mlp, into: &mid)
            geluTanh(&mid)
            linear(mid, rows: T, inDim: Self.mlp, p + "mlp.fc2", outDim: D, into: &tmp)
            tmp.withUnsafeBufferPointer { addInPlace(&h, $0.baseAddress!) }
        }
        layerNorm(h, rows: T, "vision_model.post_layernorm", into: &n)
        // Mean over the tokens (SiglipForImageClassification; the attention-pool `head` is not used by it).
        var pooled = [Float](repeating: 0, count: D)
        n.withUnsafeBufferPointer { np in
            // Column means of the T × D token matrix.
            for c in 0..<D { vDSP_meanv(np.baseAddress! + c, vDSP_Stride(D), &pooled[c], vDSP_Length(T)) }
        }
        var logits = [Float](repeating: 0, count: Self.bins)
        linear(pooled, rows: 1, inDim: D, "classifier", outDim: Self.bins, into: &logits)
        return softmax(logits).map(Float.init)
    }

    // MARK: - Kernels

    /// y[rows × outDim] = x[rows × inDim] · Wᵀ + b, W stored [outDim × inDim] (PyTorch Linear / flattened Conv).
    private func linear(_ x: [Float], rows: Int, inDim: Int, _ name: String, outDim: Int, into y: inout [Float]) {
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(outDim), Int32(inDim), 1,
                    x, Int32(inDim), w[name + ".weight"]!, Int32(inDim), 0, &y, Int32(outDim))
        let b = w[name + ".bias"]!
        y.withUnsafeMutableBufferPointer { yp in
            for r in 0..<rows {
                let row = yp.baseAddress! + r * outDim
                vDSP_vadd(row, 1, b, 1, row, 1, vDSP_Length(outDim))
            }
        }
    }

    private func layerNorm(_ x: [Float], rows: Int, _ name: String, into y: inout [Float]) {
        let D = Self.width, g = w[name + ".weight"]!, b = w[name + ".bias"]!
        x.withUnsafeBufferPointer { xp in y.withUnsafeMutableBufferPointer { yp in
            for r in 0..<rows {
                let xi = xp.baseAddress! + r * D, yi = yp.baseAddress! + r * D
                var mean: Float = 0, sq: Float = 0
                vDSP_meanv(xi, 1, &mean, vDSP_Length(D))
                var negMean = -mean
                vDSP_vsadd(xi, 1, &negMean, yi, 1, vDSP_Length(D))
                vDSP_measqv(yi, 1, &sq, vDSP_Length(D))
                var inv = 1 / (sq + Self.eps).squareRoot()
                vDSP_vsmul(yi, 1, &inv, yi, 1, vDSP_Length(D))
                vDSP_vmul(yi, 1, g, 1, yi, 1, vDSP_Length(D))
                vDSP_vadd(yi, 1, b, 1, yi, 1, vDSP_Length(D))
            }
        } }
    }

    /// y += x elementwise (y has the full T × D activation size).
    private func addInPlace(_ y: inout [Float], _ x: UnsafePointer<Float>) {
        let count = vDSP_Length(y.count)
        y.withUnsafeMutableBufferPointer { yp in vDSP_vadd(yp.baseAddress!, 1, x, 1, yp.baseAddress!, 1, count) }
    }

    private func softmaxRows(_ s: inout [Float], rows: Int, cols: Int) {
        s.withUnsafeMutableBufferPointer { sp in
            for r in 0..<rows {
                let row = sp.baseAddress! + r * cols
                var m: Float = 0
                vDSP_maxv(row, 1, &m, vDSP_Length(cols))
                var neg = -m
                vDSP_vsadd(row, 1, &neg, row, 1, vDSP_Length(cols))
                var n = Int32(cols)
                vvexpf(row, row, &n)
                var sum: Float = 0
                vDSP_sve(row, 1, &sum, vDSP_Length(cols))
                var inv = 1 / sum
                vDSP_vsmul(row, 1, &inv, row, 1, vDSP_Length(cols))
            }
        }
    }

    /// GELU, tanh approximation (`gelu_pytorch_tanh`): 0.5·x·(1 + tanh(√(2/π)·(x + 0.044715·x³))).
    private func geluTanh(_ x: inout [Float]) {
        let len = vDSP_Length(x.count)
        var n = Int32(x.count)
        var c = (2 / Float.pi).squareRoot(), k: Float = 0.044715, one: Float = 1, half: Float = 0.5
        var t = [Float](repeating: 0, count: x.count)
        x.withUnsafeMutableBufferPointer { xp in t.withUnsafeMutableBufferPointer { tp in
            let xs = xp.baseAddress!, ts = tp.baseAddress!
            vDSP_vsq(xs, 1, ts, 1, len)                    // x²
            vDSP_vsmsa(ts, 1, &k, &one, ts, 1, len)        // 1 + 0.044715·x²
            vDSP_vmul(ts, 1, xs, 1, ts, 1, len)            // x + 0.044715·x³
            vDSP_vsmul(ts, 1, &c, ts, 1, len)              // ·√(2/π)
            vvtanhf(ts, ts, &n)
            vDSP_vsadd(ts, 1, &one, ts, 1, len)            // 1 + tanh(…)
            vDSP_vmul(ts, 1, xs, 1, ts, 1, len)
            vDSP_vsmul(ts, 1, &half, xs, 1, len)
        } }
    }

    // MARK: - safetensors

    static func expectedShapes() -> [String: [Int]] {
        let D = width
        var s: [String: [Int]] = [
            "vision_model.embeddings.patch_embedding.weight": [D, 3, patch, patch],
            "vision_model.embeddings.patch_embedding.bias": [D],
            "vision_model.embeddings.position_embedding.weight": [tokens, D],
            "vision_model.post_layernorm.weight": [D], "vision_model.post_layernorm.bias": [D],
            "classifier.weight": [bins, D], "classifier.bias": [bins],
        ]
        for l in 0..<layers {
            let p = "vision_model.encoder.layers.\(l)."
            for ln in ["layer_norm1", "layer_norm2"] { s[p + ln + ".weight"] = [D]; s[p + ln + ".bias"] = [D] }
            for proj in ["q_proj", "k_proj", "v_proj", "out_proj"] {
                s[p + "self_attn.\(proj).weight"] = [D, D]; s[p + "self_attn.\(proj).bias"] = [D]
            }
            s[p + "mlp.fc1.weight"] = [mlp, D]; s[p + "mlp.fc1.bias"] = [mlp]
            s[p + "mlp.fc2.weight"] = [D, mlp]; s[p + "mlp.fc2.bias"] = [D]
        }
        return s
    }

    /// Parses the safetensors header and returns a pointer per expected tensor, checking dtype F32, shape and
    /// bounds. Any mismatch throws (fail closed: a different file is a damaged install).
    static func index(_ file: NSData, expected: [String: [Int]]) throws -> [String: UnsafePointer<Float>] {
        func bad(_ why: String) -> DetectorError { .modelLoad("age bins: \(why)") }
        guard file.length > 8 else { throw bad("short file") }
        var n: UInt64 = 0
        withUnsafeMutableBytes(of: &n) { file.getBytes($0.baseAddress!, range: NSRange(location: 0, length: 8)) }
        let headerLen = Int(UInt64(littleEndian: n))
        guard headerLen > 0, 8 + headerLen <= file.length else { throw bad("header length") }
        let header = file.subdata(with: NSRange(location: 8, length: headerLen))
        guard let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { throw bad("header") }
        let base = file.bytes + 8 + headerLen, dataLen = file.length - 8 - headerLen
        guard Int(bitPattern: base) % MemoryLayout<Float>.alignment == 0 else { throw bad("unaligned data") }
        var out: [String: UnsafePointer<Float>] = [:]
        for (name, shape) in expected {
            guard let t = json[name] as? [String: Any], t["dtype"] as? String == "F32",
                  let sh = t["shape"] as? [Int], sh == shape,
                  let off = t["data_offsets"] as? [Int], off.count == 2 else { throw bad("tensor \(name)") }
            let count = shape.reduce(1, *)
            guard off[0] >= 0, off[1] == off[0] + count * 4, off[1] <= dataLen, off[0] % 4 == 0 else {
                throw bad("offsets \(name)")
            }
            out[name] = UnsafePointer((base + off[0]).assumingMemoryBound(to: Float.self))
        }
        return out
    }
}
