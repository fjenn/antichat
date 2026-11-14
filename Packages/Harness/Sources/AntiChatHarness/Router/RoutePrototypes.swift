// M2.T22 step 1 (P-shell-13): utterance prototypes per route × language (our data, `Packages/Harness/Resources/router/route-prototypes.json`)
// and their embeddings. Ported design: aurelio-labs/semantic-router@aef8310 `semantic_router/route.py` (a route = a
// name + utterances) and `index/local.py` (one in-memory matrix of utterance vectors with a route label per row);
// MIT. The embeddings are computed once per embed model version and prototype set and cached in
// `~/Library/Caches/AntiChat/router/<sha256(model id + prototype sha)>.bin` (rows × dim little-endian Float32).
import CryptoKit
import Foundation

public struct RoutePrototypes: Sendable {
    public struct File: Codable, Sendable {
        public var version: Int
        /// top-k mean per route (semantic-router `aggregation="mean"` over the k best utterance matches).
        public var k: Int
        /// Score adjustments of the rules layer (attachment present / absent), applied to the attachment routes.
        public var attachmentBonus: Float
        public var noAttachmentPenalty: Float
        /// route → language → utterances.
        public var routes: [String: [String: [String]]]
        /// route → thresholds (M2.T23 fit); a route without an entry uses `defaultThreshold`.
        public var thresholds: [String: RouteThreshold]
        public var defaultThreshold: RouteThreshold
        /// M2.T23: "confident" also needs the top intent to beat the best intent of ANOTHER tool by this much (in
        /// threshold excess): an image/video near-tie never forces a tool. Fitted with the thresholds; nil = 0.
        public var decisiveGap: Float?
        /// The frozen dataset the thresholds were fitted on (`sha256` of router-300.jsonl), "" before fitting.
        public var datasetSHA256: String
    }

    public let file: File
    /// Flattened rows: (route, utterance) in a stable order (route, language, index).
    public let rows: [(route: Route, text: String)]
    /// sha256 of the utterance rows (the cache key part that changes with the data).
    public let sha256: String

    public init(_ file: File) {
        self.file = file
        var rows: [(Route, String)] = []
        for route in Route.allCases {
            guard let langs = file.routes[route.rawValue] else { continue }
            for lang in langs.keys.sorted() { rows += langs[lang, default: []].map { (route, $0) } }
        }
        self.rows = rows
        var h = SHA256()
        for r in rows { h.update(data: Data("\(r.0.rawValue)\t\(r.1)\n".utf8)) }
        sha256 = h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public init(data: Data) throws { self.init(try JSONDecoder().decode(File.self, from: data)) }

    /// The bundled set.
    public static let bundled: RoutePrototypes? = {
        guard let url = Bundle.module.url(forResource: "route-prototypes", withExtension: "json"),
              let d = try? Data(contentsOf: url) else { return nil }
        return try? RoutePrototypes(data: d)
    }()

    public func threshold(_ r: Route) -> RouteThreshold { file.thresholds[r.rawValue] ?? file.defaultThreshold }

    public var thresholds: [Route: RouteThreshold] {
        Dictionary(uniqueKeysWithValues: Route.intents.map { ($0, threshold($0)) })
    }

    // MARK: Embedding cache

    public static var defaultCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "AntiChat/router", directoryHint: .isDirectory)
    }

    public func cacheURL(modelID: String, directory: URL) -> URL {
        let key = SHA256.hash(data: Data("\(modelID)\n\(sha256)".utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(key).bin")
    }

    /// Cached vectors for this set (nil when absent or of the wrong shape).
    public func loadCache(_ url: URL, dim: Int? = nil) -> [[Float]]? {
        guard let d = try? Data(contentsOf: url), d.count >= 8 else { return nil }
        let (n, dm): (UInt32, UInt32) = d.withUnsafeBytes { ($0.loadUnaligned(fromByteOffset: 0, as: UInt32.self),
                                                             $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        guard Int(n) == rows.count, dm > 0, dim == nil || Int(dm) == dim, d.count == 8 + Int(n) * Int(dm) * 4 else { return nil }
        return d.withUnsafeBytes { raw in
            (0..<Int(n)).map { i in
                (0..<Int(dm)).map { j in raw.loadUnaligned(fromByteOffset: 8 + (i * Int(dm) + j) * 4, as: Float.self) }
            }
        }
    }

    public func writeCache(_ vectors: [[Float]], to url: URL) {
        guard let dim = vectors.first?.count, vectors.count == rows.count else { return }
        var d = Data(capacity: 8 + vectors.count * dim * 4)
        withUnsafeBytes(of: UInt32(vectors.count).littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(dim).littleEndian) { d.append(contentsOf: $0) }
        for v in vectors { v.withUnsafeBufferPointer { d.append(Data(buffer: $0)) } }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}
