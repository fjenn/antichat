// AT-FA-05: the Kokoro tail's conv is rewritten as shifted matmuls (no libBNNS fault on the CPU); the stage is served
// from the link folder with its other files linked, never written into the model store.
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct KokoroTailRewriteTests {
    /// The shape of the pinned tail's MIL around the op (the real file has more consts and the iSTFT after it).
    static let mil = """
        program(1.0)
        {
            func main<ios17>(tensor<fp32, [1, 128, ?]> x_pre) {
                    tensor<fp32, [22]> conv_post_bias = const()[name = tensor<string, []>("conv_post_bias"), val = tensor<fp32, [22]>(0)];
                    \(KokoroTailRewrite.convLine)
                    tensor<fp32, [1, 11, ?]> magnitude = exp(x = x)[name = tensor<string, []>("magnitude")];
            } -> (audio);
        }
        """

    @Test func theConvBecomesSevenShiftedMatmulsIntoTheSameTensor() throws {
        let out = try #require(KokoroTailRewrite.rewrite(Self.mil))
        #expect(!out.contains(" = conv("))
        #expect(out.components(separatedBy: " = matmul(").count - 1 == 7)
        #expect(out.components(separatedBy: " = slice_by_index(").count - 1 == 14)  // 7 weight taps + 7 input windows
        #expect(out.contains("pad(constant_val = kokoro_tail_mm_zero, mode = kokoro_tail_mm_mode, pad = kokoro_tail_mm_pad, x = x_pre)"))
        #expect(out.contains("val = tensor<int32, [6]>([0, 0, 0, 0, 3, 3])"))
        // The windows: k = 0 … 5 end 6 − k before the padded end, k = 6 runs to the end.
        #expect(out.contains("kokoro_tail_mm_0_xe = const()[name = tensor<string, []>(\"kokoro_tail_mm_0_xe\"), val = tensor<int32, [3]>([1, 128, -6])]"))
        #expect(out.contains("kokoro_tail_mm_6_xm = const()[name = tensor<string, []>(\"kokoro_tail_mm_6_xm\"), val = tensor<bool, [3]>([true, true, true])]"))
        #expect(out.contains("kokoro_tail_mm_5_xm = const()[name = tensor<string, []>(\"kokoro_tail_mm_5_xm\"), val = tensor<bool, [3]>([true, true, false])]"))
        // `x` is defined exactly once (by the last add) and the rest of the graph is untouched.
        #expect(out.components(separatedBy: "> x = ").count - 1 == 1)
        #expect(out.contains("tensor<fp32, [1, 22, ?]> x = add(x = kokoro_tail_mm_5_s, y = kokoro_tail_mm_6_y)"))
        #expect(out.contains("magnitude = exp(x = x)"))
        #expect(out.hasSuffix("} -> (audio);\n}"))
        // Indented like the op it replaces.
        #expect(out.contains("\n            tensor<int32, [6]> kokoro_tail_mm_pad"))
    }

    @Test func rewritingIsIdempotentAndRefusesAnotherModel() {
        let once = KokoroTailRewrite.rewrite(Self.mil)
        #expect(once.flatMap(KokoroTailRewrite.rewrite) == once)
        #expect(KokoroTailRewrite.rewrite(Self.mil.replacingOccurrences(of: "pad = x_pad_0", with: "pad = x_pad_1")) == nil)
        #expect(KokoroTailRewrite.rewrite(Self.mil + "\n" + KokoroTailRewrite.convLine) == nil)  // ambiguous
    }

    @Test func installServesARewrittenCopyAndLinksTheRest() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("tail-rewrite-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("store/\(KokoroTailRewrite.bundleName)")
        try fm.createDirectory(at: source.appendingPathComponent("weights"), withIntermediateDirectories: true)
        try Data(Self.mil.utf8).write(to: source.appendingPathComponent("model.mil"))
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("weights/weight.bin"))
        try Data([4]).write(to: source.appendingPathComponent("coremldata.bin"))
        let dest = root.appendingPathComponent("links/\(KokoroTailRewrite.bundleName)")
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dest, withDestinationURL: source)  // an older plain link is replaced

        #expect(try KokoroTailRewrite.install(source: source, destination: dest))
        #expect((try? fm.destinationOfSymbolicLink(atPath: dest.path)) == nil, "a real folder")
        #expect(try fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("weights").path) == source.appendingPathComponent("weights").path)
        #expect(try fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("coremldata.bin").path)
                == source.appendingPathComponent("coremldata.bin").path)
        let served = try String(contentsOf: dest.appendingPathComponent("model.mil"), encoding: .utf8)
        #expect(served == KokoroTailRewrite.rewrite(Self.mil))
        #expect(try String(contentsOf: source.appendingPathComponent("model.mil"), encoding: .utf8) == Self.mil, "store untouched")
        #expect(try KokoroTailRewrite.install(source: source, destination: dest), "a second load reuses the folder")

        // Another model version: served as a plain link, unchanged.
        try Data("program(1.0) {}".utf8).write(to: source.appendingPathComponent("model.mil"))
        #expect(try !KokoroTailRewrite.install(source: source, destination: dest))
        #expect(try fm.destinationOfSymbolicLink(atPath: dest.path) == source.path)
    }
}
