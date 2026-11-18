// AT-FA-05 (2026-11-09): Kokoro's last stage (`KokoroTail_v2.mlmodelc`, the iSTFT tail) crashes the helper with
// SIGSEGV in libBNNS (`BnnsCpuInferenceOperation`, KERN_INVALID_ADDRESS) whenever Core ML runs it on the CPU. Its
// first op — `conv(x_pre [1, 128, T], weight [22, 128, 7], pad 3/3)` — is what faults, for some lengths T only (about
// 1 in 7 English clauses; "I hear you mention a reverend person … How about you?" every time; macOS 26.6.2, M5 host
// with the tail forced to `.cpuOnly`, and the 8 GB clean VM, which has neither a Neural Engine nor a GPU Core ML
// uses, so every stage runs on the CPU). FluidAudio pins the tail to the GPU for this reason (#667), which only
// helps where a GPU exists.
//
// The fix keeps the model and its weights and rewrites that one op in the stage's MIL text (Core ML parses
// `model.mil` of an ML Program at load): the conv becomes seven shifted matmuls,
//   x[:, :, t] = bias + Σ_k W[:, :, k] · pad(x_pre)[:, :, t + k],   k = 0…6,
// the same arithmetic in fp32 (≈ 100 dB SNR against the original on the GPU) on BNNS's matmul path, which does not
// fault. `KokoroTTS.load` serves the rewritten stage from its own link folder; the model store is never written.
//
// 2026-11-18 ("radio" voice): the rewritten stage is wrong on the GPU once the clause is long — every clause whose
// x_pre is longer than 32 768 steps (≈ 6.8 s of speech: ≳ 105 phonemes, ≈ 273 acoustic frames) came
// out as hiss at a third of the level (first-difference/energy ratio ≈ 1.0 against ≈ 0.15, RMS 0.017 against 0.05),
// while the shipped stage on the GPU and the rewritten one on the CPU stay clean (padding by concat and a time-major
// matmul fail the same way). So the rewrite is served only where the tail really runs on the CPU: the tail pinned to
// the CPU, or a Mac whose Core ML has no GPU (the clean VM). Everywhere else the shipped stage is linked unchanged.
import CoreML
import FluidAudio
import Foundation

enum KokoroTailRewrite {
    /// The tail's compiled model folder (FluidAudio `KokoroAneStage.tail.bundleName`).
    static let bundleName = "KokoroTail_v2.mlmodelc"

    /// Whether Core ML runs the tail on the CPU for `units` (the only place the rewrite is needed and correct).
    static func tailRunsOnCPU(_ units: KokoroAneComputeUnits,
                              gpuAvailable: Bool = MLComputeDevice.allComputeDevices.contains { if case .gpu = $0 { true } else { false } }) -> Bool {
        !(gpuAvailable && (units.tail == .cpuAndGPU || units.tail == .all))
    }

    /// The op the rewrite replaces, exactly as the pinned model (kokoro-82m-coreml@2568276) spells it.
    static let convLine = "tensor<fp32, [1, 22, ?]> x = conv(bias = conv_post_bias, dilations = x_dilations_0, "
        + "groups = x_groups_0, pad = x_pad_0, pad_type = x_pad_type_0, strides = x_strides_0, weight = weight_1, "
        + "x = x_pre)[name = tensor<string, []>(\"x\")];"
    static let marker = "kokoro_tail_mm"

    /// `mil` with the conv replaced by the shifted matmuls; nil when `mil` does not hold the expected op once (another
    /// model version: it is then served unchanged).
    static func rewrite(_ mil: String) -> String? {
        if mil.contains(marker) { return mil }
        let lines = mil.components(separatedBy: "\n")
        let hits = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == convLine }
        guard hits.count == 1, let i = hits.first else { return nil }
        let indent = String(lines[i].prefix { $0 == " " })
        var ops: [String] = []
        func const(_ name: String, _ type: String, _ value: String) {
            ops.append("\(type) \(name) = const()[name = tensor<string, []>(\"\(name)\"), val = \(type)(\(value))];")
        }
        func op(_ type: String, _ name: String, _ call: String) {
            ops.append("\(type) \(name) = \(call)[name = tensor<string, []>(\"\(name)\")];")
        }
        // Zero padding 3/3 on the time axis (the conv's `pad = [3, 3]`).
        const("\(marker)_pad", "tensor<int32, [6]>", "[0, 0, 0, 0, 3, 3]")
        const("\(marker)_mode", "tensor<string, []>", "\"constant\"")
        const("\(marker)_zero", "tensor<fp32, []>", "0x0p+0")
        op("tensor<fp32, [1, 128, ?]>", "\(marker)_x",
           "pad(constant_val = \(marker)_zero, mode = \(marker)_mode, pad = \(marker)_pad, x = x_pre)")
        const("\(marker)_bshape", "tensor<int32, [3]>", "[1, 22, 1]")
        op("tensor<fp32, [1, 22, 1]>", "\(marker)_b", "reshape(shape = \(marker)_bshape, x = conv_post_bias)")
        const("\(marker)_wshape", "tensor<int32, [2]>", "[22, 128]")
        const("\(marker)_false", "tensor<bool, []>", "false")
        var sum = "\(marker)_b"
        for k in 0..<7 {
            let p = "\(marker)_\(k)"
            const("\(p)_wb", "tensor<int32, [3]>", "[0, 0, \(k)]")
            const("\(p)_we", "tensor<int32, [3]>", "[22, 128, \(k + 1)]")
            op("tensor<fp32, [22, 128, 1]>", "\(p)_w3", "slice_by_index(begin = \(p)_wb, end = \(p)_we, x = weight_1)")
            op("tensor<fp32, [22, 128]>", "\(p)_w", "reshape(shape = \(marker)_wshape, x = \(p)_w3)")
            // pad(x)[:, :, k : k + T] (the end is relative to the padded length T + 6; k = 6 runs to the end).
            const("\(p)_xb", "tensor<int32, [3]>", "[0, 0, \(k)]")
            const("\(p)_xe", "tensor<int32, [3]>", "[1, 128, \(k - 6)]")
            const("\(p)_xm", "tensor<bool, [3]>", "[true, true, \(k == 6)]")
            op("tensor<fp32, [1, 128, ?]>", "\(p)_xs",
               "slice_by_index(begin = \(p)_xb, end = \(p)_xe, end_mask = \(p)_xm, x = \(marker)_x)")
            op("tensor<fp32, [1, 22, ?]>", "\(p)_y",
               "matmul(transpose_x = \(marker)_false, transpose_y = \(marker)_false, x = \(p)_w, y = \(p)_xs)")
            let next = k == 6 ? "x" : "\(p)_s"
            op("tensor<fp32, [1, 22, ?]>", next, "add(x = \(sum), y = \(p)_y)")
            sum = next
        }
        var out = lines
        out.replaceSubrange(i...i, with: ops.map { indent + $0 })
        return out.joined(separator: "\n")
    }

    /// Serves the tail stage at `destination` (a real folder): every file of `source` linked, `model.mil` rewritten.
    /// Falls back to a plain link of `source` when its MIL is not the expected one. Returns whether it rewrote.
    @discardableResult
    static func install(source: URL, destination: URL) throws -> Bool {
        let fm = FileManager.default
        let milURL = source.appendingPathComponent("model.mil")
        guard let mil = try? String(contentsOf: milURL, encoding: .utf8), let rewritten = rewrite(mil) else {
            if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != source.path {
                try? fm.removeItem(at: destination)
                try fm.createSymbolicLink(at: destination, withDestinationURL: source)
            }
            return false
        }
        if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: source.path) where name != "model.mil" {
            let at = destination.appendingPathComponent(name), to = source.appendingPathComponent(name)
            if (try? fm.destinationOfSymbolicLink(atPath: at.path)) != to.path {
                try? fm.removeItem(at: at)
                try fm.createSymbolicLink(at: at, withDestinationURL: to)
            }
        }
        let target = destination.appendingPathComponent("model.mil")
        if (try? String(contentsOf: target, encoding: .utf8)) != rewritten {
            try Data(rewritten.utf8).write(to: target, options: .atomic)
        }
        return true
    }
}
