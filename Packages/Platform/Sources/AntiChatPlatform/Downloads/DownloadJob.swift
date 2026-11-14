// M2.T08 (R-204, R-220 AC3; blueprint E §E.2.5): one file to fetch, keyed by its sha256 (the queue never holds two
// jobs for the same bytes, R-204 AC7). Persisted as a `download` row.
import AntiChatFoundation
import AntiChatStorage
import Foundation

public struct DownloadRequest: Sendable, Equatable {
    public var sha256: String
    public var size: Int64
    /// In order: the first that works is used; 404/410 moves to the next (R-220 AC3, E.2.5).
    public var sources: [URL]
    /// Optional per-chunk sha256 (catalog `chunk{size, sha256[]}`).
    public var chunk: CatalogChunk?
    public var modelID: String?
    /// The pack the file is fetched for (`chat`, `voice`, …); also the `{pack}` of `download.unavailable`.
    public var pack: String
    /// Lower runs first (InstallQueue order, E.2.4).
    public var priority: Int

    public init(sha256: String, size: Int64, sources: [URL], chunk: CatalogChunk? = nil, modelID: String? = nil,
                pack: String = "chat", priority: Int = 0) {
        self.sha256 = sha256; self.size = size; self.sources = sources; self.chunk = chunk; self.modelID = modelID
        self.pack = pack; self.priority = priority
    }

    /// The request for one catalog file of `model`.
    public init(file: CatalogFile, model: CatalogModel?, pack: String, priority: Int = 0) {
        self.init(sha256: file.sha256, size: file.size,
                  sources: file.sources.compactMap(URL.init(string:)).map { Self.rewritten($0) }, chunk: file.chunk,
                  modelID: model?.id, pack: pack, priority: priority)
    }

    /// DEBUG `-DownloadHost <url>` (M2.T09; wired in M10.T09 for the clean-VM suite's local mirror): a source on
    /// `https://huggingface.co` is fetched from `<url>` with the same path (the bytes are still sha256-verified against
    /// the signed catalog). Release builds never parse the option, so this is the identity there.
    public static func rewritten(_ url: URL, host: String? = LaunchOptions.current.downloadHost) -> URL {
        let hf = "https://huggingface.co/"
        guard let host, url.absoluteString.hasPrefix(hf) else { return url }
        let base = host.hasSuffix("/") ? host : host + "/"
        return URL(string: base + url.absoluteString.dropFirst(hf.count)) ?? url
    }
}

public struct DownloadJob: Sendable, Equatable, Identifiable {
    public enum State: String, Sendable, Codable, CaseIterable {
        case queued, running, paused, verifying, done, failed, cancelled
        public var isTerminal: Bool { self == .done || self == .failed || self == .cancelled }
    }
    /// Why a job is paused: the user's button, or the system (network, sleep, disk, power — T09 resumes these).
    public enum PauseReason: String, Sendable, Codable { case user, system }

    public var id: String
    public var request: DownloadRequest
    public var state: State
    public var pauseReason: PauseReason?
    public var bytesDone: Int64
    public var retries: Int
    /// Copy key of the last error (`download.unavailable`, `download.verifyFailed`, `download.failed`, …).
    public var errorKey: String?
    public var createdAt: Date

    public init(id: String, request: DownloadRequest, state: State, pauseReason: PauseReason?, bytesDone: Int64, retries: Int,
                errorKey: String?, createdAt: Date) {
        self.id = id; self.request = request; self.state = state; self.pauseReason = pauseReason; self.bytesDone = bytesDone
        self.retries = retries; self.errorKey = errorKey; self.createdAt = createdAt
    }

    public var sha256: String { request.sha256 }
    public var bytesTotal: Int64 { request.size }
}

extension DownloadJob {
    init(record r: DownloadRecord) {
        let sources = (r.sources.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [r.url])
            .compactMap(URL.init(string:))
        let chunk = r.chunkSHA.flatMap { try? JSONDecoder().decode(CatalogChunk.self, from: Data($0.utf8)) }
        self.init(id: r.id,
                  request: DownloadRequest(sha256: r.fileSHA256, size: r.bytesTotal ?? 0, sources: sources, chunk: chunk,
                                           modelID: r.modelID, pack: r.pack ?? "chat", priority: r.priority),
                  state: State(rawValue: r.state) ?? .queued, pauseReason: r.pauseReason.flatMap(PauseReason.init(rawValue:)),
                  bytesDone: r.bytesDone, retries: r.retries, errorKey: r.error, createdAt: r.createdAt)
    }

    func record(chunkMap: String?) -> DownloadRecord {
        let sources = String(decoding: (try? JSONEncoder().encode(request.sources.map(\.absoluteString))) ?? Data(), as: UTF8.self)
        let chunk = request.chunk.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        return DownloadRecord(id: id, fileSHA256: sha256, url: request.sources.first?.absoluteString ?? "", bytesDone: bytesDone,
                              bytesTotal: request.size, state: state.rawValue, retries: retries, chunkMap: chunkMap,
                              createdAt: createdAt, updatedAt: Date(), pack: request.pack, priority: request.priority,
                              modelID: request.modelID, sources: sources, chunkSHA: chunk, pauseReason: pauseReason?.rawValue,
                              error: errorKey)
    }
}
