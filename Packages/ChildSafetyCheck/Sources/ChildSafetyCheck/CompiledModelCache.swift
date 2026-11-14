// Install-time form of the compiled Core ML detectors (M4 T1 time-to-final-image, NFR-P1).
//
// ONNX Runtime's CoreML EP compiles each detector into `<cache>/<hash>/<n>_static_mlprogram/model/
// compiled_model.mlmodelc` (one per partition). For MatMul weights it writes the transposed matrix as an IMMEDIATE
// constant: the weights are spelled out as hex-float text inside `model.mil` (Freepik: ~74 MB of text per partition,
// ~1.1 GB in all; MiVOLO ~0.3 GB). Every MLModel load then parses that text and, to look up its on-device (E5)
// compiled form, serialises the whole program to text again to hash it: ~95 % of the detector load (sampled:
// `E5BundleCacheKeyUtils::ToE5BundleCacheKey → MIL::IRProgram::ToString → SerializeImmediateTensorDim<float>`).
//
// `compact` moves every large immediate fp32 constant into the partition's own weight file (MIL blob storage v2: a
// 64-byte header per blob, data 64-byte aligned) and replaces the text with a `BLOBFILE` reference, exactly as Core ML
// stores every other weight. Hex floats parse exactly, so the program and every weight are bit-identical: the
// partition computes the same outputs (checked bit for bit on random inputs, and the calibration sets give the same
// verdicts). Nothing about the published model files changes (D-007): only our own compiled cache.
// Each file is replaced atomically (temp + rename; the weight file first, whose existing offsets stay valid), and a
// marker next to the bundle makes later calls a no-op. Any parse surprise leaves that partition as it was.
import Darwin
import Foundation

package enum CompiledModelCache {
    static let marker = "antichat-compacted"
    /// Immediates shorter than this stay inline (scalars, small vectors: not worth a blob).
    static let minLineBytes = 4096
    /// The largest constant moved (elements): a malformed or hostile shape larger than any detector weight is left
    /// inline rather than allocated (M4 review: overflow-checked dims with a size cap).
    static let maxElements = 1 << 28

    /// Reads a partition's weight file (injectable so tests can fail it).
    package typealias WeightReader = @Sendable (URL) throws -> Data

    /// Compacts every compiled partition under `directory`; returns how many partitions changed.
    /// M9 review E1: throws when a partition's existing weight file exists but cannot be read. That partition is left
    /// as it was with no marker (a later call retries), and the caller fails closed instead of loading a cache whose
    /// blob offsets were computed against a stand-in empty weight file.
    @discardableResult
    package static func compact(_ directory: URL,
                                readWeights: WeightReader = { try Data(contentsOf: $0) }) throws -> Int {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var bundles: [URL] = []
        for case let url as URL in walker where url.lastPathComponent == "compiled_model.mlmodelc" {
            bundles.append(url)
            walker.skipDescendants()
        }
        // M4 review: one partition at a time (each holds its model.mil text + parsed floats + weight file in memory;
        // in parallel that peaked far above the T1 budget).
        var changed = 0
        var firstError: Error?
        for b in bundles {
            do {
                if try compactBundle(b, readWeights: readWeights) { changed += 1 }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return changed
    }

    /// True when the bundle was rewritten (false: already compact, nothing to move, or not understood).
    /// Throws (no marker written, nothing changed) when the weight file exists but cannot be read.
    static func compactBundle(_ bundle: URL, readWeights: WeightReader = { try Data(contentsOf: $0) }) throws -> Bool {
        let fm = FileManager.default
        let markerURL = bundle.deletingLastPathComponent().appendingPathComponent(marker)
        if fm.fileExists(atPath: markerURL.path) { return false }
        let milURL = bundle.appendingPathComponent("model.mil")
        let weightURL = bundle.appendingPathComponent("weights/weight.bin")
        guard let mil = try? Data(contentsOf: milURL, options: .alwaysMapped) else { return false }
        // M9 review E1: only "no such file" means a partition without a weight file. Any other read error would make
        // the new blobs' offsets point into a fresh file while the existing BLOBFILE references keep theirs, and the
        // marker would stop any retry: rethrow instead.
        var weights: Data
        do {
            weights = try readWeights(weightURL)
        } catch where Self.isNoSuchFile(error) {
            weights = Self.emptyWeightFile()
        }
        guard weights.count >= 64, weights.readUInt32(0) != nil else { return false }
        var count = weights.readUInt32(0)!
        var out = Data(capacity: mil.count < 1 << 20 ? mil.count : 1 << 20)
        var moved = 0
        var lineStart = 0
        let bytes = [UInt8](mil)
        while lineStart < bytes.count {
            var end = lineStart
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            let line = bytes[lineStart..<end]
            if line.count >= minLineBytes, let r = externalize(line, weights: &weights) {
                out.append(contentsOf: r)
                count += 1
                moved += 1
            } else {
                out.append(contentsOf: line)
            }
            if end < bytes.count { out.append(0x0A) }
            lineStart = end + 1
        }
        guard moved > 0 else {
            try? Data().write(to: markerURL)
            return false
        }
        weights.writeUInt32(count, at: 0)
        do {
            try fm.createDirectory(at: weightURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replace(weightURL, with: weights)
            try replace(milURL, with: out)
            try Data().write(to: markerURL)
            return true
        } catch {
            return false
        }
    }

    /// `<prefix>val = tensor<fp32, [d0, …]>([[…]])];` → the same declaration with a BLOBFILE value; the floats are
    /// appended to `weights`. nil when the line is not a large fp32 immediate constant (left unchanged).
    static func externalize(_ line: ArraySlice<UInt8>, weights: inout Data) -> [UInt8]? {
        let head = Array(line.prefix(512))
        guard find(head, "= const()[name = string(") != nil, let val = find(head, "val = tensor<fp32, ["),
              let close = find(head, "]>(", from: val) else { return nil }
        let dimsStart = val + "val = tensor<fp32, [".utf8.count
        let dims = String(decoding: head[dimsStart..<close], as: UTF8.self).split(separator: ",")
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !dims.isEmpty, dims.allSatisfy({ ($0 ?? 0) > 0 }) else { return nil }
        guard let expected = elementCount(dims.map { $0! }) else { return nil }
        // The immediate value starts right after "]>(".
        let valueStart = line.startIndex + close + 3
        guard valueStart < line.endIndex, line[valueStart] == UInt8(ascii: "[") else { return nil }
        let suffix: [UInt8] = Array(")];".utf8)
        guard line.count > suffix.count, Array(line.suffix(suffix.count)) == suffix else { return nil }
        // Parse every number between valueStart and the closing ")];" (exact: strtof reads hex floats exactly).
        var text = Array(line[valueStart..<(line.endIndex - suffix.count)])
        text.append(0)
        var values = [Float]()
        values.reserveCapacity(expected)
        let ok: Bool = text.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { base in
                var p = base
                let endPtr = base + buf.count - 1
                while p < endPtr {
                    let c = UInt8(bitPattern: p.pointee)
                    if c == UInt8(ascii: "[") || c == UInt8(ascii: "]") || c == UInt8(ascii: ",") || c == UInt8(ascii: " ") {
                        p += 1
                        continue
                    }
                    var next: UnsafeMutablePointer<CChar>?
                    let v = strtof(p, &next)
                    guard let next, next > p else { return false }
                    values.append(v)
                    p = next
                }
                return true
            }
        }
        guard ok, values.count == expected else { return nil }
        // Blob: metadata (sentinel, dtype fp32 = 2, size, data offset, padding) at a 64-byte boundary, then the data.
        while weights.count % 64 != 0 { weights.append(0) }
        let meta = weights.count
        let size = UInt64(expected * 4)
        var header = Data(count: 64)
        header.writeUInt32(0xDEAD_BEEF, at: 0)
        header.writeUInt32(2, at: 4)
        header.writeUInt64(size, at: 8)
        header.writeUInt64(UInt64(meta + 64), at: 16)
        weights.append(header)
        values.withUnsafeBufferPointer { weights.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: $0.count * 4)) }
        var result = Array(line[line.startIndex..<valueStart])
        result.append(contentsOf: Array("BLOBFILE(path = string(\"@model_path/weights/weight.bin\"), offset = uint64(\(meta)))".utf8))
        result.append(contentsOf: suffix)
        return result
    }

    /// Product of `dims` with overflow checks, nil when it overflows or exceeds `maxElements`.
    static func elementCount(_ dims: [Int]) -> Int? {
        var n = 1
        for d in dims {
            let (m, o) = n.multipliedReportingOverflow(by: d)
            guard !o, m <= maxElements else { return nil }
            n = m
        }
        return n
    }

    /// First index of `needle` in `hay` at or after `from`.
    static func find(_ hay: [UInt8], _ needle: String, from: Int = 0) -> Int? {
        let n = Array(needle.utf8)
        guard hay.count >= n.count, from <= hay.count - n.count else { return nil }
        for i in from...(hay.count - n.count) where hay[i] == n[0] && Array(hay[i..<i + n.count]) == n { return i }
        return nil
    }

    /// True for a "file does not exist" error only (Cocoa or POSIX ENOENT); every other error is a real read failure.
    static func isNoSuchFile(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, e.code == CocoaError.fileReadNoSuchFile.rawValue || e.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        if e.domain == NSPOSIXErrorDomain, e.code == Int(ENOENT) { return true }
        return false
    }

    /// A blob-storage v2 file with no blobs (a partition whose weights were all immediate).
    static func emptyWeightFile() -> Data {
        var d = Data(count: 64)
        d.writeUInt32(0, at: 0)
        d.writeUInt32(2, at: 4)
        return d
    }

    /// Atomic replace: write a temp file, fsync it (a crash never leaves a renamed-but-empty file), then rename.
    static func replace(_ url: URL, with data: Data) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: tmp)
        let fd = open(tmp.path, O_RDONLY)
        guard fd >= 0 else { try? FileManager.default.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
        let synced = fsync(fd) == 0
        close(fd)
        guard synced else { try? FileManager.default.removeItem(at: tmp); throw CocoaError(.fileWriteUnknown) }
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

final class CountBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: Int
    init(_ v: Int) { self.v = v }
    func add(_ n: Int) { lock.withLock { v += n } }
    var value: Int { lock.withLock { v } }
}

extension Data {
    func readUInt32(_ at: Int) -> UInt32? {
        guard at + 4 <= count else { return nil }
        return self[startIndex + at..<startIndex + at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    mutating func writeUInt32(_ v: UInt32, at: Int) {
        Swift.withUnsafeBytes(of: v.littleEndian) { replaceSubrange(startIndex + at..<startIndex + at + 4, with: $0) }
    }

    mutating func writeUInt64(_ v: UInt64, at: Int) {
        Swift.withUnsafeBytes(of: v.littleEndian) { replaceSubrange(startIndex + at..<startIndex + at + 8, with: $0) }
    }
}
