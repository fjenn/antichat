// M2.T11 test support: a two-version catalog — `starter` and `starter-v2` (supersedes starter; new config, shared
// tokenizer + weights, so the update costs only the new blob) — served by range-server.py, the starter installed in
// slot chat/normal/chat_fast, and a ModelUpdateService on a fake path / disk / activity.
@testable import AntiChatPlatform
import AntiChatNetwork
import AntiChatStorage
import Foundation

final class UpdateFixture: @unchecked Sendable {
    static let slot = "chat/normal/chat_fast"
    let dir: URL
    let server: RangeServer
    let v1: ModelCatalog
    let v2: ModelCatalog
    let models: ModelsDirectory
    let db: AppDatabase
    let dl: DownloadCoordinator
    let tracker = PackActivityTracker()
    private let lock = NSLock()
    private var _catalog: ModelCatalog
    var catalog: ModelCatalog {
        get { lock.withLock { _catalog } }
        set { lock.withLock { _catalog = newValue } }
    }

    init(_ tag: String, v2Supersedes: Bool = true) async throws {
        dir = DL.tempDir(tag)
        let cfg = try DL.makeBlob(in: dir, name: "config.json", size: 64 * 1024, seed: 11)
        let cfg2 = try DL.makeBlob(in: dir, name: "config-v2.json", size: 96 * 1024, seed: 12)
        let tok = try DL.makeBlob(in: dir, name: "tokenizer.json", size: 2 * TransferConfig.mib, seed: 13)
        let w = try DL.makeBlob(in: dir, name: "model.safetensors", size: 3 * TransferConfig.mib, seed: 14)
        server = try RangeServer(root: dir)
        let srv = server
        func file(_ path: String, _ b: DL.Blob) -> [String: Any] {
            ["path": path, "size": b.size, "sha256": b.sha256, "sources": [srv.url(b.name).absoluteString]]
        }
        func model(_ files: [[String: Any]], supersedes: [String]? = nil) -> [String: Any] {
            var m: [String: Any] = ["role": "chat", "engine": "mlx-swift-lm", "format": "mlx-safetensors", "capabilities": ["chat"],
                                    "noncommercial_ok": true, "repo": "org/repo", "commit": String(repeating: "a", count: 40),
                                    "footprint": ["weights_gb": 0.01, "kv_per_token_kb": 1, "overhead_gb": 0.1], "files": files]
            if let supersedes { m["supersedes"] = supersedes }
            return m
        }
        func cat(_ version: Int, _ models: [String: Any]) throws -> ModelCatalog {
            let json: [String: Any] = [
                "schema": 2, "catalog_version": version, "issued": "2026-11-01T00:00:00Z", "expires": "2027-11-01T00:00:00Z",
                "min_app_version": "0.0.1", "revoked": [], "roles": ["chat_fast"], "tone_sentence": "", "assignments": [:] as [String: Any],
                "models": models,
            ]
            return try ModelCatalog.decode(JSONSerialization.data(withJSONObject: json))
        }
        let starter = model([file("config.json", cfg), file("tokenizer.json", tok), file("model.safetensors", w)])
        v1 = try cat(100, ["starter": starter])
        v2 = try cat(110, ["starter": starter,
                           "starter-v2": model([file("config.json", cfg2), file("tokenizer.json", tok), file("model.safetensors", w)],
                                               supersedes: v2Supersedes ? ["starter"] : nil)])
        _catalog = v1
        models = ModelsDirectory(root: dir.appending(path: "Models"))
        try models.create()
        db = try AppDatabase.inMemory()
        dl = DownloadCoordinator(models: models, database: db, config: TransferConfig(chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
        for j in await dl.enqueue(model: v1.models["starter"]!, pack: "chat") { _ = await dl.wait(j.id) }
        try InstallView.materialize(v1.models["starter"]!, catalogVersion: 100, models: models, database: db, slot: Self.slot)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func service(path: PathStatus.State = .ok, autoUpdate: Bool = true, freeGB: Int64 = 500) -> ModelUpdateService {
        ModelUpdateService(models: models, database: db, catalog: { [self] in catalog }, activity: tracker, autoUpdate: { autoUpdate },
                           path: { path }, freeBytes: { freeGB * 1_000_000_000 }, coordinator: dl, enabled: { true })
    }

    func row() async throws -> ModelInstallRecord? { try await db.read { try ModelInstallRecord.fetchOne($0, key: Self.slot) } }

    /// Requests the range server saw for the new config blob (0 = nothing downloaded).
    var v2Requests: Int { server.records().filter { $0.path.hasSuffix("/config-v2.json") }.count }
}
