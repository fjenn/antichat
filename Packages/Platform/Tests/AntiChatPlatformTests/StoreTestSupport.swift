// M2.T10 test support: a Normal and an Evil fixture model sharing `tokenizer.json` (the NFR-D5 / R-293 AC1 shape),
// served by range-server.py, in a local catalog JSON the CLI can read.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation

final class StoreFixture: @unchecked Sendable {
    let dir: URL
    let server: RangeServer
    let catalog: ModelCatalog
    let catalogURL: URL
    let models: ModelsDirectory
    var blobs: [String: DL.Blob] = [:]

    init(_ tag: String, sizesMB: [String: Int64] = ["tokenizer.json": 3, "model.safetensors": 6, "config.json": 1, "evil.gguf": 5],
         serverArgs: [String] = []) throws {
        let dir = DL.tempDir(tag)
        var bl: [String: DL.Blob] = [:]
        for (i, (name, mb)) in sizesMB.sorted(by: { $0.key < $1.key }).enumerated() {
            bl[name] = try DL.makeBlob(in: dir, name: name, size: mb * TransferConfig.mib + Int64(i * 4099), seed: UInt64(100 + i))
        }
        let srv = try RangeServer(root: dir, args: serverArgs)
        func file(_ n: String) -> [String: Any] {
            let b = bl[n]!
            return ["path": n, "size": b.size, "sha256": b.sha256, "sources": [srv.url(n).absoluteString]]
        }
        func model(_ engine: String, _ format: String, _ files: [String]) -> [String: Any] {
            ["role": "chat", "engine": engine, "format": format, "capabilities": ["chat"], "noncommercial_ok": true, "repo": "org/repo",
             "commit": String(repeating: "a", count: 40), "footprint": ["weights_gb": 0.01, "kv_per_token_kb": 1, "overhead_gb": 0.1],
             "files": files.map(file)]
        }
        let json: [String: Any] = [
            "schema": 2, "catalog_version": 7, "issued": "2026-11-01T00:00:00Z", "expires": "2027-11-01T00:00:00Z", "min_app_version": "0.0.1",
            "revoked": [], "roles": ["chat_fast"], "tone_sentence": "", "assignments": [:] as [String: Any],
            "models": ["norm": model("mlx-swift-lm", "mlx-safetensors", ["config.json", "tokenizer.json", "model.safetensors"]),
                       "evil": model("llama.cpp", "gguf", ["tokenizer.json", "evil.gguf"])],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let curl = dir.appending(path: "catalog.json")
        try data.write(to: curl)
        self.dir = dir
        blobs = bl
        server = srv
        models = ModelsDirectory(root: dir.appending(path: "Models"))
        catalogURL = curl
        catalog = try ModelCatalog.decode(data)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func coordinator(_ db: AppDatabase? = nil) -> DownloadCoordinator {
        DownloadCoordinator(models: models, database: db, config: TransferConfig(chunkSize: 2 * TransferConfig.mib), sleep: DL.fastSleep)
    }

    /// Downloads and materialises `ids` in-process.
    func install(_ ids: [String], db: AppDatabase? = nil, dl: DownloadCoordinator? = nil) async throws {
        try models.create()
        let dl = dl ?? coordinator(db)
        for id in ids {
            let m = catalog.models[id]!
            for j in await dl.enqueue(model: m, pack: "chat") { _ = await dl.wait(j.id) }
            try InstallView.materialize(m, catalogVersion: catalog.catalogVersion, models: models, database: db, slot: db == nil ? nil : "chat/\(id)/chat")
        }
    }

    /// `du -sk` of the Models folder, in bytes.
    func du() throws -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", models.root.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (Int64(s.split(separator: "\t").first ?? "0") ?? 0) * 1024
    }
}
