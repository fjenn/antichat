// Owner bug 2026-11-16 (Evil Mode: 85 GB verified in the store, no install view, "not available on this Mac yet"):
// `SetupInstaller.reconcile` finishes every model this Mac should have from what is already on disk.
//   * every file in the store, no view → the view (and its slot) is written, nothing is fetched;
//   * an interrupted download → the restored job resumes from its bitmap and its end writes the view;
//   * only a small companion missing → that file alone is fetched;
//   * a wrong size in the store, or a download that fails its checksum twice → an error the UI can show with Retry
//     (the store's file is kept: only Repair deletes a blob);
//   * a pack that was never downloaded is not started behind the user's back, and does not hold Evil back;
//   * Evil turned on in Settings (`addEvil` alone, no `start` in the process) gets its view when its file ends.
// Everything runs in temporary directories against the local range server.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import GRDB
import Testing

@Suite(.serialized) struct InstallReconcileTests {
    final class Fixture: @unchecked Sendable {
        let dir: URL
        let server: RangeServer
        let catalog: ModelCatalog
        let models: ModelsDirectory
        let blobs: [String: DL.Blob]

        /// `evil` mirrors the owner's model: weights, a README shared with the Normal model, an mmproj in a folder.
        init(args: [String] = []) throws {
            dir = DL.tempDir("reconcile")
            let sizes: [(String, Int64)] = [("weights.gguf", 4 * TransferConfig.mib + 811), ("README.md", 96_892),
                                            ("mmproj.gguf", TransferConfig.mib + 17), ("tier.bin", 2 * TransferConfig.mib + 5)]
            var bl: [String: DL.Blob] = [:]
            for (i, (n, size)) in sizes.enumerated() { bl[n] = try DL.makeBlob(in: dir, name: n, size: size, seed: UInt64(900 + i)) }
            blobs = bl
            server = try RangeServer(root: dir, args: args)
            let srv = server
            func file(_ n: String, _ path: String) -> [String: Any] {
                ["path": path, "size": bl[n]!.size, "sha256": bl[n]!.sha256, "sources": [srv.url(n).absoluteString]]
            }
            func model(_ engine: String, _ files: [[String: Any]]) -> [String: Any] {
                ["role": "chat", "engine": engine, "format": engine == "llama.cpp" ? "gguf" : "mlx-safetensors", "capabilities": ["chat"],
                 "noncommercial_ok": true, "repo": "org/repo", "commit": String(repeating: "b", count: 40),
                 "footprint": ["weights_gb": 0.01, "kv_per_token_kb": 1, "overhead_gb": 0.1], "files": files]
            }
            let json: [String: Any] = [
                "schema": 2, "catalog_version": 17, "issued": "2026-11-01T00:00:00Z", "expires": "2027-11-01T00:00:00Z", "min_app_version": "0.0.1",
                "revoked": [], "roles": ["chat_fast"], "tone_sentence": "", "assignments": [:] as [String: Any],
                "models": [
                    "evil": model("llama.cpp", [file("weights.gguf", "weights-Q4_K_M.gguf"), file("README.md", "README.md"),
                                                file("mmproj.gguf", "mmproj/mmproj-BF16.gguf")]),
                    "tier": model("mlx-swift-lm", [file("README.md", "README.md"), file("tier.bin", "model.safetensors")]),
                ],
            ]
            catalog = try ModelCatalog.decode(try JSONSerialization.data(withJSONObject: json))
            models = ModelsDirectory(root: dir.appending(path: "Models"))
            try models.create()
        }
        deinit { try? FileManager.default.removeItem(at: dir) }

        /// The item with every file of the model (what the app derives from the enabled packs and Evil Mode).
        func item(_ id: String, _ mode: ModelMode) -> InstallPlan.Item {
            let m = catalog.models[id]!
            let group = mode == .evil ? "evil" : "chat"
            return .init(modelID: id, pack: .chat, mode: mode, role: "chat",
                         requests: m.files.enumerated().map { DownloadRequest(file: $1, model: m, pack: group, priority: $0) })
        }

        /// Puts a verified copy of `name` in the store, as a finished download left it.
        func store(_ name: String) throws {
            let b = blobs[name]!
            let part = models.part(b.sha256)
            try FileManager.default.copyItem(at: b.url, to: part)
            try BlobStore(models: models).commit(partial: part, sha256: b.sha256)
        }

        func coordinator(_ db: AppDatabase? = nil) -> DownloadCoordinator {
            DownloadCoordinator(models: models, database: db, config: TransferConfig(chunkSize: TransferConfig.mib), sleep: DL.fastSleep)
        }

        func hasView(_ id: String) -> Bool {
            FileManager.default.fileExists(atPath: models.install(id).appending(path: "manifest.json").path)
        }

        func waitView(_ id: String, seconds: Double = 30) async -> Bool {
            for _ in 0..<Int(seconds * 20) {
                if hasView(id) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return hasView(id)
        }
    }

    static let free: Int64 = 500_000_000_000

    /// The owner's Mac: the download finished (row `done`, every file in the store) in a process that had nobody to
    /// write the view. The next launch installs from the store: no request leaves, the Evil chat slot points at it.
    @Test func everyFileInTheStoreAndNoView_installsWithoutNetwork() async throws {
        let fx = try Fixture()
        let db = try AppDatabase.inMemory()
        for n in ["weights.gguf", "README.md", "mmproj.gguf"] { try fx.store(n) }
        let w = fx.blobs["weights.gguf"]!
        let row = DownloadJob(id: "j1", request: DownloadRequest(file: fx.catalog.models["evil"]!.files[0], model: fx.catalog.models["evil"], pack: "evil", priority: 10_000),
                              state: .done, pauseReason: nil, bytesDone: w.size, retries: 0, errorKey: nil, createdAt: Date())
        try db.write { try row.record(chunkMap: nil).save($0) }
        #expect(!fx.hasView("evil"))

        let dl = fx.coordinator(db)
        try await dl.restore()
        let setup = SetupInstaller(coordinator: dl, database: db, catalog: { fx.catalog })
        let report = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free)

        #expect(report.installed == ["evil"])
        #expect(report.failed.isEmpty && report.fetching.isEmpty && report.waiting.isEmpty)
        #expect(fx.hasView("evil"))
        #expect(await setup.installed.contains("evil"))
        #expect(await setup.failures.isEmpty)
        // The view's files are the store's (symlinks for llama.cpp): the same bytes, nothing copied or fetched.
        let weights = fx.models.install("evil").appending(path: "weights-Q4_K_M.gguf")
        #expect(weights.resolvingSymlinksInPath().path == dl.blobs.url(w.sha256).resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: fx.models.install("evil").appending(path: "mmproj/mmproj-BF16.gguf").path))
        #expect(fx.server.records().isEmpty, "no request may leave: \(fx.server.records().map(\.path))")
        #expect(await dl.allJobs.allSatisfy { $0.state == .done })
        let slot = try await db.read { try ModelInstallRecord.fetchOne($0, key: "chat/evil/chat") }
        #expect(slot?.catalogEntryID == "evil" && slot?.state == "ready")
        // Again (every launch): nothing changes, still no request.
        let again = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free)
        #expect(again == SetupInstaller.ReconcileReport())
        #expect(fx.server.records().isEmpty)
    }

    /// The app is quit mid-download. The next launch restores the job (bitmap) and reconcile makes sure its end
    /// writes the view; the part is continued, not fetched again.
    @Test func interruptedDownload_resumesFromThePartAndInstalls() async throws {
        let fx = try Fixture(args: ["--slow", "1500"])
        let db = try AppDatabase.inMemory()
        try fx.store("README.md")
        try fx.store("mmproj.gguf")
        let w = fx.blobs["weights.gguf"]!
        var dl: DownloadCoordinator? = fx.coordinator(db)
        let first = SetupInstaller(coordinator: dl!, database: db, catalog: { fx.catalog })
        await first.addEvil([fx.item("evil", .evil)])
        var before: Int64 = 0
        for _ in 0..<200 {
            before = ChunkBitmap.load(fx.models.bitmap(w.sha256))?.bytesDone ?? 0
            if before >= 2 * TransferConfig.mib { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(before >= TransferConfig.mib, "the first run fetched nothing")
        // Quit: the running job stops where it is (its row says running / system-paused, its part and bitmap stay).
        for j in await dl!.allJobs { await dl!.pause(j.id, reason: .system) }
        try await Task.sleep(for: .milliseconds(300))
        dl = nil
        #expect(!fx.hasView("evil"))
        #expect(FileManager.default.fileExists(atPath: fx.models.part(w.sha256).path))

        // Relaunch.
        let dl2 = fx.coordinator(db)
        try await dl2.restore()
        let setup = SetupInstaller(coordinator: dl2, database: db, catalog: { fx.catalog })
        let report = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free)
        #expect(report.waiting == ["evil"])
        #expect(report.fetching.isEmpty && report.failed.isEmpty)
        #expect(await fx.waitView("evil"))
        #expect(await setup.installed.contains("evil"))
        // Resumed: over both runs the server sent the file once (plus at most the chunks cut off by the quit).
        let sent = await fx.server.settledSent("weights.gguf", atLeast: w.size)
        #expect(sent < w.size + 3 * TransferConfig.mib, "sent \(sent) of \(w.size): the part was not resumed")
        #expect(fx.server.sent("README.md") == 0 && fx.server.sent("mmproj.gguf") == 0)
    }

    /// The weights are here, the README never arrived and nothing is fetching it: only the README is fetched.
    @Test func missingCompanion_isFetchedOnItsOwn() async throws {
        let fx = try Fixture()
        try fx.store("weights.gguf")
        try fx.store("mmproj.gguf")
        let readme = fx.blobs["README.md"]!
        let dl = fx.coordinator()
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        let report = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free)
        #expect(report.fetching == ["evil": [readme.sha256]])
        #expect(await fx.waitView("evil"))
        #expect(await fx.server.settledSent("README.md", atLeast: readme.size) == readme.size)
        #expect(fx.server.sent("weights.gguf") == 0 && fx.server.sent("mmproj.gguf") == 0)
        #expect(await setup.failures.isEmpty)
    }

    /// A companion cannot be fetched while the catalog may not install anything: an error, not a silent wait.
    @Test func missingCompanion_withACatalogThatMayNotInstall_isAnError() async throws {
        let fx = try Fixture()
        try fx.store("weights.gguf")
        try fx.store("mmproj.gguf")
        let dl = fx.coordinator()
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        let report = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: false, free: Self.free)
        #expect(report.failed == ["evil": InstallFailure.catalog])
        #expect(await setup.failures == ["evil": InstallFailure.catalog])
        #expect(await dl.allJobs.isEmpty && fx.server.records().isEmpty)
        // Retry once the catalog is fine again.
        let retry = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free, retry: true)
        #expect(retry.fetching["evil"]?.count == 1)
        #expect(await fx.waitView("evil"))
        #expect(await setup.failures.isEmpty)
    }

    /// A file in the store that is not the size the catalog names is not installed: an error state, the file kept
    /// (reconcile never deletes), nothing fetched over it.
    @Test func wrongSizeInTheStore_isAnErrorAndTheFileStays() async throws {
        let fx = try Fixture()
        try fx.store("README.md")
        try fx.store("mmproj.gguf")
        let w = fx.blobs["weights.gguf"]!
        let dl = fx.coordinator()
        let short = dl.blobs.url(w.sha256)
        try FileManager.default.createDirectory(at: short.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: 1000).write(to: short)
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        let report = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free)
        #expect(report.failed == ["evil": InstallFailure.corrupt])
        #expect(report.installed.isEmpty)
        #expect(await setup.failures == ["evil": InstallFailure.corrupt])
        #expect(!fx.hasView("evil"))
        #expect(SetupInstaller.size(short) == 1000, "the file must stay for inspection")
        #expect(await dl.allJobs.isEmpty && fx.server.records().isEmpty)
        // A later queue event does not install it behind the error.
        _ = await dl.enqueue(DL.request(fx.blobs["README.md"]!, server: fx.server))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!fx.hasView("evil"))
    }

    /// The download fails its full-file checksum twice: `download.failed` reaches the installer's failures (the UI's
    /// Retry). The existing policy stands: the mismatched part is deleted, nothing wrong enters the store.
    @Test func checksumFailure_isAnErrorState() async throws {
        let fx = try Fixture(args: ["--corrupt", "weights.gguf"])
        try fx.store("README.md")
        try fx.store("mmproj.gguf")
        let w = fx.blobs["weights.gguf"]!
        let dl = fx.coordinator()
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        await setup.addEvil([fx.item("evil", .evil)])
        var key: String?
        for _ in 0..<600 {
            key = await setup.failures["evil"]
            if key != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(key == "download.failed")
        #expect(!fx.hasView("evil"))
        #expect(!dl.blobs.contains(w.sha256))
        #expect(!FileManager.default.fileExists(atPath: fx.models.part(w.sha256).path))
        // The next launch-style pass keeps saying so (no silent re-download loop); Retry requeues the failed job.
        let report = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free)
        #expect(report.failed == ["evil": "download.failed"])
        let failedJobs = await dl.allJobs.filter { $0.state == .failed }
        #expect(failedJobs.count == 1)
        let retry = await setup.reconcile([fx.item("evil", .evil)], mayInstallNew: true, free: Self.free, retry: true)
        #expect(retry.waiting == ["evil"])
    }

    /// A model none of whose own files is here (only the README it shares) and that nothing is fetching: reconcile
    /// starts no download for it, and it does not hold the Evil variants back.
    @Test func neverDownloadedModel_isNotStartedAndDoesNotBlockEvil() async throws {
        let fx = try Fixture()
        for n in ["weights.gguf", "README.md", "mmproj.gguf"] { try fx.store(n) }
        let dl = fx.coordinator()
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        let report = await setup.reconcile([fx.item("tier", .normal)], mayInstallNew: true, free: Self.free)
        #expect(report.absent == ["tier"])
        #expect(await dl.allJobs.isEmpty && fx.server.records().isEmpty)
        await setup.addEvil([fx.item("evil", .evil)])
        #expect(await setup.evilQueued)
        #expect(fx.hasView("evil"))
        #expect(!fx.hasView("tier"))
        #expect(fx.server.records().isEmpty)
    }

    /// Evil turned on in Settings: `addEvil` alone, no `start` in this process. Its file's end writes the view.
    @Test func evilFromSettings_installsWhenItsDownloadEnds() async throws {
        let fx = try Fixture()
        let dl = fx.coordinator()
        let setup = SetupInstaller(coordinator: dl, database: nil, catalog: { fx.catalog })
        await setup.addEvil([fx.item("evil", .evil)])
        #expect(await fx.waitView("evil"))
        #expect(await setup.installed.contains("evil"))
    }
}
