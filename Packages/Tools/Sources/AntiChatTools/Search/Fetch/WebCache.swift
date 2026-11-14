// M7.T02 step 8 (blueprint B §B1.2 step 10): fetched pages are cached for 24 h in `~/Library/Caches/AntiChat/web/`
// (≤ 200 MB, oldest evicted first, cleared with "Clear cache"); an incognito chat uses the in-memory cache only, so
// nothing it fetched touches the disk (R-093, disk-diff test).
import CryptoKit
import Foundation

public protocol WebCache: Sendable {
    func get(_ url: URL) -> FetchedPage?
    func put(_ page: FetchedPage)
    func clear()
}

public final class MemoryWebCache: WebCache, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [URL: FetchedPage] = [:]
    public let ttl: TimeInterval
    public init(ttl: TimeInterval = 24 * 3600) { self.ttl = ttl }
    public func get(_ url: URL) -> FetchedPage? {
        lock.withLock {
            guard var p = pages[url], Date().timeIntervalSince(p.fetchedAt) < ttl else { return nil }
            p.fromCache = true
            return p
        }
    }
    public func put(_ page: FetchedPage) { lock.withLock { pages[page.requestedURL] = page } }
    public func clear() { lock.withLock { pages.removeAll() } }
}

public final class DiskWebCache: WebCache, @unchecked Sendable {
    public let directory: URL
    public let ttl: TimeInterval
    public let maxBytes: Int
    private let lock = NSLock()

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "AntiChat/web", directoryHint: .isDirectory)
    }

    public init(directory: URL = DiskWebCache.defaultDirectory, ttl: TimeInterval = 24 * 3600, maxBytes: Int = 200 * 1024 * 1024) {
        self.directory = directory; self.ttl = ttl; self.maxBytes = maxBytes
    }

    struct Meta: Codable { var requestedURL: URL; var url: URL; var contentType: String; var fetchedAt: Date }

    func key(_ url: URL) -> String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }

    public func get(_ url: URL) -> FetchedPage? {
        lock.withLock {
            let k = key(url)
            guard let md = try? Data(contentsOf: directory.appending(path: "\(k).json")),
                  let m = try? JSONDecoder().decode(Meta.self, from: md), Date().timeIntervalSince(m.fetchedAt) < ttl,
                  let body = try? Data(contentsOf: directory.appending(path: "\(k).body")) else { return nil }
            return FetchedPage(requestedURL: m.requestedURL, url: m.url, status: 200, contentType: m.contentType, data: body,
                               fetchedAt: m.fetchedAt, fromCache: true)
        }
    }

    public func put(_ page: FetchedPage) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let k = key(page.requestedURL)
            let meta = Meta(requestedURL: page.requestedURL, url: page.url, contentType: page.contentType, fetchedAt: page.fetchedAt)
            try? page.data.write(to: directory.appending(path: "\(k).body"), options: .atomic)
            try? JSONEncoder().encode(meta).write(to: directory.appending(path: "\(k).json"), options: .atomic)
            evict()
        }
    }

    public func clear() { lock.withLock { try? FileManager.default.removeItem(at: directory) } }

    /// Drops expired entries, then the oldest until the folder is ≤ `maxBytes`.
    private func evict() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { f -> (URL, Date, Int)? in
            guard let v = try? f.resourceValues(forKeys: Set(keys)) else { return nil }
            return (f, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
        }.sorted { $0.1 < $1.1 }
        var total = entries.reduce(0) { $0 + $1.2 }
        let now = Date()
        while let first = entries.first, total > maxBytes || now.timeIntervalSince(first.1) > ttl {
            try? FileManager.default.removeItem(at: first.0)
            total -= first.2
            entries.removeFirst()
        }
    }
}
