// M6 review #2 (P1): every zip path we own inflates through `BoundedZip`, which counts the bytes it actually produces.
// A part over its cap, an archive over its total and an import part over its ratio cap stop mid-stream; a header that
// under-declares the size does not help (the declared `uncompressedSize` is never trusted).
//   make test-unit FILTER=BoundedZipTests
import Foundation
import Testing
import ZIPFoundation
@testable import AntiChatStorage

enum ZipBomb {
    /// An in-memory zip whose parts are `(name, bytes)`; bytes of one repeated value deflate ~1000:1.
    static func archive(_ parts: [(String, Data)]) throws -> Data {
        let a = try Archive(accessMode: .create)
        for (name, data) in parts {
            try a.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        return a.data!
    }
    static func spaces(_ n: Int) -> Data { Data(repeating: 0x20, count: n) }
}

@Suite(.serialized) struct BoundedZipTests {
    @Test func partOverItsCapStopsMidStream() throws {
        let zip = try ZipBomb.archive([("small.txt", Data("hello".utf8)), ("bomb.xml", ZipBomb.spaces(80 << 20))])
        #expect(zip.count < 1 << 20, "the bomb is small on disk")
        let z = try BoundedZip(data: zip)
        #expect(try z.data("small.txt") == Data("hello".utf8))
        #expect(throws: BoundedZipError.partTooLarge("bomb.xml", BoundedZip.documentPartCap)) { try z.data("bomb.xml") }
        #expect(z.inflated <= BoundedZip.documentPartCap + 5 + (1 << 20), "inflation stopped at the cap")
        #expect(throws: BoundedZipError.partTooLarge("bomb.xml", BoundedZip.documentPartCap)) { try BoundedZip(data: zip).checkAll() }
    }

    @Test func totalCapCountsEveryPartRead() throws {
        let zip = try ZipBomb.archive([("a", ZipBomb.spaces(600_000)), ("b", ZipBomb.spaces(600_000))])
        let z = try BoundedZip(data: zip, partCap: 1 << 20, totalCap: 1_000_000)
        _ = try z.data("a")
        #expect(throws: BoundedZipError.totalTooLarge(1_000_000)) { try z.data("b") }
    }

    @Test func underDeclaredSizeIsNotTrusted() throws {
        var zip = try ZipBomb.archive([("bomb.xml", ZipBomb.spaces(70 << 20))])
        // Patch the central directory's and the local header's uncompressed size to 100 bytes.
        func patch(sig: [UInt8], at off: Int) {
            var i = 0
            while let r = zip.range(of: Data(sig), in: i..<zip.count) {
                let o = r.lowerBound + off
                zip.replaceSubrange(o..<o + 4, with: [100, 0, 0, 0])
                i = r.upperBound
            }
        }
        patch(sig: [0x50, 0x4B, 0x01, 0x02], at: 24)
        patch(sig: [0x50, 0x4B, 0x03, 0x04], at: 22)
        let z = try BoundedZip(data: zip)
        #expect(throws: BoundedZipError.self) { try z.data("bomb.xml") }
        #expect(z.inflated <= BoundedZip.documentPartCap + (1 << 20))
    }

    @Test func importRatioCapStopsAConversationsBomb() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var json = Data(#"[{"title":"x","mapping":{},"current_node":null,"pad":""#.utf8)
        json.append(ZipBomb.spaces(80 << 20)); json.append(Data(#""}]"#.utf8))
        let url = dir.appendingPathComponent("export.zip")
        try ZipBomb.archive([("conversations.json", json)]).write(to: url)
        let rig = try ImportRig()
        defer { rig.cleanup() }
        #expect(throws: BoundedZipError.self) { try rig.importer.run(url) }
    }
}
