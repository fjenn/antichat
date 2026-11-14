// M2.T08 (R-204 AC3, NFR-D6; blueprint E §E.2.5): which bytes of a `.part` file are already on disk.
// Persisted as `partial/<sha256>.bitmap` (and mirrored into `download.chunk_map`). Finished chunks are a bitset;
// the chunks in flight keep a watermark (bytes from the chunk start already written), saved every
// `watermarkInterval` bytes, so a resume — after a network loss, a pause or `kill -9` — re-fetches at most one
// watermark interval per lane, never a whole chunk per lane (4 lanes × 64 MB would break NFR-D6's ≤ 64 MB).
// Design from osaurus@2922745 ChunkedFileDownloader.swift `PartManifest` (finished chunks only); the watermark
// is ours.
import Foundation

public struct ChunkBitmap: Codable, Sendable, Equatable {
    public var sha256: String
    public var size: Int64
    public var chunkSize: Int64
    /// Bit i set = chunk i is complete (and, when the catalog has chunk hashes, verified).
    public var bits: [UInt8]
    /// Chunk index → bytes already written from the chunk start (chunks in flight only).
    public var watermarks: [Int: Int64]

    public init(sha256: String, size: Int64, chunkSize: Int64) {
        self.sha256 = sha256
        self.size = size
        self.chunkSize = max(1, chunkSize)
        bits = [UInt8](repeating: 0, count: (Self.count(size: size, chunkSize: self.chunkSize) + 7) / 8)
        watermarks = [:]
    }

    static func count(size: Int64, chunkSize: Int64) -> Int { size == 0 ? 1 : Int((size + chunkSize - 1) / chunkSize) }

    public var chunkCount: Int { Self.count(size: size, chunkSize: chunkSize) }

    public func range(_ i: Int) -> ClosedRange<Int64> {
        let start = Int64(i) * chunkSize
        return start...max(start, min(start + chunkSize, size) - 1)
    }

    public func length(_ i: Int) -> Int64 { size == 0 ? 0 : range(i).count.int64 }

    public func isDone(_ i: Int) -> Bool { bits[i / 8] & (1 << UInt8(i % 8)) != 0 }

    public mutating func markDone(_ i: Int) {
        bits[i / 8] |= 1 << UInt8(i % 8)
        watermarks[i] = nil
    }

    public mutating func reset(_ i: Int) {
        bits[i / 8] &= ~(1 << UInt8(i % 8))
        watermarks[i] = nil
    }

    public var pending: [Int] { (0..<chunkCount).filter { !isDone($0) } }
    public var isComplete: Bool { pending.isEmpty }

    /// Bytes on disk: finished chunks plus the watermarks of the chunks in flight.
    public var bytesDone: Int64 {
        (0..<chunkCount).reduce(Int64(0)) { $0 + (isDone($1) ? length($1) : min(watermarks[$1] ?? 0, length($1))) }
    }

    /// Same file, same chunk layout: the part on disk may be resumed.
    public func matches(sha256: String, size: Int64, chunkSize: Int64) -> Bool {
        self.sha256 == sha256 && self.size == size && self.chunkSize == chunkSize
    }

    // MARK: Persistence

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func load(_ url: URL) -> ChunkBitmap? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChunkBitmap.self, from: d)
    }

    public func save(_ url: URL) throws { try encoded().write(to: url, options: .atomic) }
}

extension Int {
    var int64: Int64 { Int64(self) }
}
