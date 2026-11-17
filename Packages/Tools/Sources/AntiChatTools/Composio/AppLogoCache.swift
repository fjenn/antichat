// The colour logos of apps this build does not bundle (apps the relay's live list added): loaded from the URL the
// relay passed on from Composio, only over https from Composio's logo host (`isAllowed`), one at a time when a
// row asks, and kept in `directory` up to `capBytes` (the least recently used go first). Only bytes that are an
// image (PNG, JPEG, GIF, WebP or SVG) of at most `maxLogoBytes` are kept; Composio's generic placeholder for an app
// without a logo is not (the row shows the app's initial). Offline only = no request.
import AntiChatNetwork
import CryptoKit
import Foundation

public actor AppLogoCache {
    public static let maxLogoBytes = 256 * 1024

    public let directory: URL
    private let capBytes: Int
    private let allowed: @Sendable () -> Bool
    private let loader: DirectoryCatalogs.Loader
    /// Files that failed in this run (asked again after a relaunch).
    private var failed: Set<String> = []
    private var running: [String: Task<Data?, Never>] = [:]

    public init(directory: URL, capBytes: Int = 16 * 1024 * 1024,
                allowed: @escaping @Sendable () -> Bool = { NetworkPolicyStore.shared.isEnabled(.catalog) },
                loader: @escaping DirectoryCatalogs.Loader = DirectoryCatalogs.gated) {
        self.directory = directory; self.capBytes = capBytes; self.allowed = allowed; self.loader = loader
    }

    /// Composio's logo host, the only one a logo is loaded from (a handful of apps list a logo elsewhere: those
    /// show their initial).
    public static let host = "logos.composio.dev"

    /// https, no credentials or odd port, and Composio's logo host.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host()?.lowercased() else { return false }
        return host == Self.host
    }

    /// The logo URL of a live app, when it is one this cache would load.
    public static func logoURL(_ string: String) -> URL? {
        guard string.count <= 300, let url = URL(string: string), isAllowed(url) else { return nil }
        return url
    }

    /// PNG, JPEG, GIF, WebP or SVG by its first bytes; never Composio's placeholder.
    static func isImage(_ data: Data) -> Bool {
        guard data.count >= 16, data.count <= maxLogoBytes else { return false }
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8, 0xFF]) || head.starts(with: Array("GIF8".utf8)) { return true }
        if head.starts(with: Array("RIFF".utf8)), Array(head[8...]) == Array("WEBP".utf8) { return true }
        let text = String(decoding: data.prefix(2000), as: UTF8.self)
        return text.contains("<svg") && data.range(of: Data("composio-fallback".utf8)) == nil
    }

    /// The logo of `slug` from `url`: from the folder when it is there, else one request. nil = none.
    public func logo(slug: String, url: URL) async -> Data? {
        guard DirectoryCatalogs.isSlug(slug), Self.isAllowed(url) else { return nil }
        // The file name follows the URL: a logo Composio moves is fetched again.
        let name = slug + "." + Self.digest(Data(url.absoluteString.utf8)).prefix(12) + ".logo"
        if let task = running[name] { return await task.value }
        let file = directory.appending(path: name)
        if let data = try? Data(contentsOf: file), Self.isImage(data) {
            // Used again: counts as recent for the cap (at most one metadata write a day per logo).
            let day = Date().addingTimeInterval(-24 * 3600)
            if let m = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < day {
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            }
            return data
        }
        guard !failed.contains(name), allowed() else { return nil }
        let task = Task<Data?, Never> { [loader] in
            guard let answer = try? await loader(URLRequest(url: url)), answer.status == 200, Self.isImage(answer.data) else { return nil }
            return answer.data
        }
        running[name] = task
        let data = await task.value
        running[name] = nil
        guard let data else { failed.insert(name); return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for old in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where old.hasPrefix(slug + ".") && old.hasSuffix(".logo") && old != name {
            try? FileManager.default.removeItem(at: directory.appending(path: old))
        }
        try? data.write(to: file, options: .atomic)
        trim()
        return data
    }

    /// Removes the least recently used logos until the folder is within the cap.
    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? [])
            .filter { $0.pathExtension == "logo" }
            .compactMap { u -> (url: URL, size: Int, date: Date)? in
                guard let v = try? u.resourceValues(forKeys: keys) else { return nil }
                return (u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
            }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files.sorted(by: { ($0.date, $0.url.lastPathComponent) < ($1.date, $1.url.lastPathComponent) }) where total > capBytes {
            try? FileManager.default.removeItem(at: f.url)
            total -= f.size
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
