// M0.T10 spike → M2.T08 (R-204 AC4, NFR-D6 "every file sha256-verified before use"): streaming hashes.
// The full-file sha256 runs before a part becomes a blob (`BlobStore.commit`); the range hash checks one chunk
// against the catalog's optional `chunk.sha256[i]`.
import CryptoKit
import Foundation

public enum Verify {
    static let block = 4 * 1024 * 1024

    /// Streaming sha256 of a file (4 MB blocks), lowercase hex. `cancelled` is polled between blocks.
    public static func sha256(_ url: URL, cancelled: () -> Bool = { false }) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let data = try h.read(upToCount: block), !data.isEmpty {
            if cancelled() { throw CancellationError() }
            hasher.update(data: data)
        }
        return hex(hasher.finalize())
    }

    /// sha256 of `length` bytes at `offset`.
    public static func sha256(_ url: URL, offset: Int64, length: Int64) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(offset))
        var hasher = SHA256()
        var left = length
        while left > 0, let data = try h.read(upToCount: Int(min(Int64(block), left))), !data.isEmpty {
            hasher.update(data: data)
            left -= Int64(data.count)
        }
        return hex(hasher.finalize())
    }

    /// Git blob sha1 (`blob <size>\0` + bytes): what the HF tree API's `oid` is for non-LFS files.
    public static func gitBlobSHA1(_ url: URL) throws -> String {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size?.int64Value ?? 0)\0".utf8))
        while let data = try h.read(upToCount: block), !data.isEmpty { hasher.update(data: data) }
        return hex(hasher.finalize())
    }

    /// `^[0-9a-f]{64}$` (ollama manifest/paths.go digest rule; blobs are named by it).
    public static func isSHA256Hex(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
}
