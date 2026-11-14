// M6 review #2 (P1, zip bombs): the one bounded zip reader every zip path we own goes through (DOCX headings, EPUB
// members, XLSX date styles, the DOCX pre-check before AppKit's importer, chat-export images). ZIPFoundation inflates
// as a stream; the consumer counts the bytes it actually produced, so a part over `partCap` or an archive over
// `totalCap` stops mid-stream (the declared `uncompressedSize` is never trusted). A per-part ratio cap (output ≤
// compressed × `maxRatio`, above a floor) is optional, for paths whose legitimate size is open-ended (chat imports).
import Foundation
import ZIPFoundation

public enum BoundedZipError: Error, Equatable, Sendable {
    case notAnArchive
    /// One part inflated past its cap (the name and the cap in bytes).
    case partTooLarge(String, Int)
    /// The parts read so far inflated past the archive's total cap.
    case totalTooLarge(Int)
    case corrupt(String)
}

private struct SinkError: Error { let error: any Error }

public final class BoundedZip {
    /// Documents: no real OOXML/EPUB part comes near 64 MB of XML; the total covers embedded media.
    public static let documentPartCap = 64 << 20
    public static let documentTotalCap = 512 << 20

    public let partCap: Int
    public let totalCap: Int
    public let maxRatio: Int?
    public private(set) var inflated = 0
    private let archive: Archive
    private lazy var byName: [String: Entry] = {
        var m: [String: Entry] = [:]
        for e in archive where e.type == .file && m[e.path] == nil { m[e.path] = e }
        return m
    }()

    public init(url: URL, partCap: Int = documentPartCap, totalCap: Int = documentTotalCap, maxRatio: Int? = nil) throws {
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw BoundedZipError.notAnArchive }
        self.partCap = partCap; self.totalCap = totalCap; self.maxRatio = maxRatio
    }

    /// Chat exports: multi-GB `conversations.json` is legitimate, so imports bound each part by its compression ratio
    /// (JSON and images stay far below 250:1; a deflate bomb runs near 1000:1).
    public static let importRatio = 250
    public static let importPartCap = 32 << 30
    public static let importTotalCap = 64 << 30

    /// Wraps an archive the caller already opened (the importers).
    public init(archive: Archive, partCap: Int, totalCap: Int, maxRatio: Int? = nil) {
        self.archive = archive
        self.partCap = partCap; self.totalCap = totalCap; self.maxRatio = maxRatio
    }

    public init(data: Data, partCap: Int = documentPartCap, totalCap: Int = documentTotalCap, maxRatio: Int? = nil) throws {
        do { archive = try Archive(data: data, accessMode: .read) } catch { throw BoundedZipError.notAnArchive }
        self.partCap = partCap; self.totalCap = totalCap; self.maxRatio = maxRatio
    }

    public var names: [String] { byName.keys.sorted() }

    /// Every entry's path and whether it is a symlink, read from the central directory without inflating anything
    /// (M6.T21 review #9: the runtime installer checks paths BEFORE extracting).
    public static func entries(of url: URL) throws -> [(path: String, isSymlink: Bool)] {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw BoundedZipError.notAnArchive }
        return archive.map { ($0.path, $0.type == .symlink) }
    }
    public func contains(_ name: String) -> Bool { byName[name] != nil }

    /// The part's bytes, or nil when there is no such part.
    public func data(_ name: String) throws -> Data? {
        guard let e = byName[name] else { return nil }
        var out = Data()
        try stream(e) { out.append($0) }
        return out
    }

    /// Inflates `name` into `url` (a new file), bounded like `data`; a partial file is removed on failure.
    public func extract(_ name: String, to url: URL) throws {
        guard let e = byName[name] else { throw BoundedZipError.corrupt("no part \(name)") }
        try extract(e, to: url)
    }

    public func extract(_ e: Entry, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil), let h = try? FileHandle(forWritingTo: url) else {
            throw BoundedZipError.corrupt("cannot write \(url.lastPathComponent)")
        }
        do {
            try stream(e) { try h.write(contentsOf: $0) }
            try h.close()
        } catch {
            try? h.close(); try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Inflates every part without keeping it: proves the whole archive is within the caps before a reader we do not
    /// control (AppKit's OOXML importer) inflates it.
    public func checkAll() throws {
        for name in names { try stream(byName[name]!) { _ in } }
    }

    /// Streams one entry's inflated bytes to `sink` within the caps (`sink` may throw to stop early).
    public func stream(_ e: Entry, _ sink: (Data) throws -> Void) throws {
        var part = 0
        var cap = partCap
        if let r = maxRatio { cap = min(partCap, max(Self.documentPartCap, Int(clamping: e.compressedSize) &* r)) }
        do {
            _ = try archive.extract(e, skipCRC32: false) { chunk in
                part += chunk.count
                if part > cap { throw BoundedZipError.partTooLarge(e.path, cap) }
                if inflated + chunk.count > totalCap { throw BoundedZipError.totalTooLarge(totalCap) }
                inflated += chunk.count
                do { try sink(chunk) } catch { throw SinkError(error: error) }
            }
        } catch let b as BoundedZipError {
            throw b
        } catch let s as SinkError {
            throw s.error  // the sink's own stop or write failure
        } catch {
            throw BoundedZipError.corrupt("\(e.path): \(error)")
        }
    }
}
