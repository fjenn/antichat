// CompiledModelCache (M4 T1 detector load): large immediate fp32 constants of a compiled partition move into its weight
// file bit for bit, everything else in the program text is unchanged, and a second pass is a no-op.
import Foundation
import Testing
@testable import ChildSafetyCheck

@Suite struct CompiledModelCacheTests {
    static func bundle() throws -> (URL, [Float]) {
        let root = FileManager.default.temporaryDirectory.appending(path: "csc-cache-\(UUID().uuidString)")
        let b = root.appending(path: "123/0_static_mlprogram/model/compiled_model.mlmodelc")
        try FileManager.default.createDirectory(at: b.appending(path: "weights"), withIntermediateDirectories: true)
        // 40 × 30 values (> minLineBytes as text), hex floats incl. negatives, zero and a subnormal-ish small value.
        var values: [Float] = []
        for i in 0..<1200 { values.append(Float(i % 7 - 3) * 0.0078125 + (i == 5 ? 1e-30 : 0)) }
        let rows = stride(from: 0, to: 1200, by: 30).map { r in
            "[" + values[r..<r + 30].map { String(format: "%a", Double($0)) }.joined(separator: ", ") + "]"
        }
        let small = "            tensor<fp32, [2]> b = const()[name = string(\"b\"), val = tensor<fp32, [2]>([0x1p+0, -0x1p+0])];"
        let blob = "            tensor<fp32, [4]> g = const()[name = string(\"g\"), val = tensor<fp32, [4]>(BLOBFILE(path = string(\"@model_path/weights/weight.bin\"), offset = uint64(64)))];"
        let big = "            tensor<fp32, [40, 30]> w_t = const()[name = string(\"w_t\"), val = tensor<fp32, [40, 30]>([\(rows.joined(separator: ", "))])];"
        let mil = ["program(1.3)", "{", "    func main<ios18>(tensor<fp32, [1, 30]> x) {", small, blob, big, "    } -> (x);", "}"].joined(separator: "\n")
        try Data(mil.utf8).write(to: b.appending(path: "model.mil"))
        // Existing weight file: header (1 blob) + the 4-float blob of `g` at offset 64.
        var w = Data(count: 64)
        w.writeUInt32(1, at: 0); w.writeUInt32(2, at: 4)
        var meta = Data(count: 64)
        meta.writeUInt32(0xDEAD_BEEF, at: 0); meta.writeUInt32(2, at: 4); meta.writeUInt64(16, at: 8); meta.writeUInt64(128, at: 16)
        w.append(meta)
        [Float](arrayLiteral: 1, 2, 3, 4).withUnsafeBufferPointer { w.append(Data(buffer: $0)) }
        try w.write(to: b.appending(path: "weights/weight.bin"))
        return (root, values)
    }

    @Test func movesLargeImmediatesBitForBit() throws {
        let (root, values) = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let b = root.appending(path: "123/0_static_mlprogram/model/compiled_model.mlmodelc")
        let before = try String(contentsOf: b.appending(path: "model.mil"), encoding: .utf8)
        #expect(try CompiledModelCache.compact(root) == 1)
        let mil = try String(contentsOf: b.appending(path: "model.mil"), encoding: .utf8)
        let w = try Data(contentsOf: b.appending(path: "weights/weight.bin"))
        // Only the big line changed; it now references a blob.
        let a = before.split(separator: "\n"), c = mil.split(separator: "\n")
        #expect(a.count == c.count)
        for (x, y) in zip(a, c) where !x.contains("w_t") { #expect(x == y) }
        let line = try #require(c.first { $0.contains("w_t") })
        let offset = try #require(line.range(of: #"offset = uint64\((\d+)\)"#, options: .regularExpression)
            .map { Int(line[$0].dropFirst("offset = uint64(".count).dropLast())! })
        #expect(line.hasSuffix("val = tensor<fp32, [40, 30]>(BLOBFILE(path = string(\"@model_path/weights/weight.bin\"), offset = uint64(\(offset))))];"))
        #expect(offset % 64 == 0 && w.readUInt32(0) == 2)
        #expect(w.readUInt32(offset) == 0xDEAD_BEEF && w.readUInt32(offset + 4) == 2)
        let data = w.subdata(in: (offset + 64)..<(offset + 64 + 1200 * 4))
        let back = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(back.map(\.bitPattern) == values.map(\.bitPattern))
        // The earlier blob is untouched.
        #expect(w.subdata(in: 128..<144).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } == [1, 2, 3, 4])
        // Idempotent.
        #expect(try CompiledModelCache.compact(root) == 0)
        #expect(try String(contentsOf: b.appending(path: "model.mil"), encoding: .utf8) == mil)
    }

    /// M4 review: shapes are overflow-checked and capped; an absurd shape leaves the line inline (nothing allocated).
    @Test func hugeOrOverflowingShapesStayInline() {
        #expect(CompiledModelCache.elementCount([4, 8]) == 32)
        #expect(CompiledModelCache.elementCount([Int.max, 2]) == nil)
        #expect(CompiledModelCache.elementCount([1 << 20, 1 << 20]) == nil)
        let line = Array("    tensor<fp32, [65536, 65536]> w = const()[name = string(\"w\"), val = tensor<fp32, [65536, 65536]>([0x1p+0])];".utf8)
        var weights = CompiledModelCache.emptyWeightFile()
        #expect(CompiledModelCache.externalize(line[...], weights: &weights) == nil)
        #expect(weights.count == 64)
    }

    /// M9 review E1: a weight file that exists but cannot be read is not "no weight file". The compaction throws,
    /// leaves model.mil and the weight file untouched and writes no marker, so a later call retries and succeeds.
    @Test func unreadableWeightFileThrowsAndRetriesLater() throws {
        let (root, _) = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let b = root.appending(path: "123/0_static_mlprogram/model/compiled_model.mlmodelc")
        let mil = try Data(contentsOf: b.appending(path: "model.mil"))
        let weights = try Data(contentsOf: b.appending(path: "weights/weight.bin"))
        let ioError = CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EIO)])
        #expect(throws: CocoaError.self) { try CompiledModelCache.compact(root, readWeights: { _ in throw ioError }) }
        #expect(throws: POSIXError.self) { try CompiledModelCache.compact(root, readWeights: { _ in throw POSIXError(.EACCES) }) }
        #expect(try Data(contentsOf: b.appending(path: "model.mil")) == mil)
        #expect(try Data(contentsOf: b.appending(path: "weights/weight.bin")) == weights)
        #expect(!FileManager.default.fileExists(atPath: b.deletingLastPathComponent().appending(path: CompiledModelCache.marker).path))
        // The retry with a working read compacts against the real weight file (the earlier blob keeps its offset).
        #expect(try CompiledModelCache.compact(root) == 1)
        let w = try Data(contentsOf: b.appending(path: "weights/weight.bin"))
        #expect(w.readUInt32(0) == 2)
        #expect(w.subdata(in: 128..<144).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } == [1, 2, 3, 4])
    }

    /// Only a missing weight file falls back to an empty one (a partition whose weights were all immediate).
    @Test func missingWeightFileStartsEmpty() throws {
        let (root, values) = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let b = root.appending(path: "123/0_static_mlprogram/model/compiled_model.mlmodelc")
        try FileManager.default.removeItem(at: b.appending(path: "weights/weight.bin"))
        #expect(try CompiledModelCache.compact(root) == 1)
        let w = try Data(contentsOf: b.appending(path: "weights/weight.bin"))
        #expect(w.readUInt32(0) == 1)
        #expect(w.readUInt32(64) == 0xDEAD_BEEF)
        let back = w.subdata(in: 128..<(128 + 1200 * 4)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(back.map(\.bitPattern) == values.map(\.bitPattern))
        #expect(CompiledModelCache.isNoSuchFile(CocoaError(.fileReadNoSuchFile)))
        #expect(CompiledModelCache.isNoSuchFile(POSIXError(.ENOENT)))
        #expect(!CompiledModelCache.isNoSuchFile(POSIXError(.EIO)))
        #expect(!CompiledModelCache.isNoSuchFile(CocoaError(.fileReadNoPermission)))
    }
}
