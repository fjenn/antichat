// M8.T10 (AT-205 AC1–AC4/AC7, AT-NFR-D8, AT-NFR-D7 pre-check) over a seeded scratch tree (`DataPaths` rooted in a temp
// dir, the ANTICHAT_ROOT shape):
//   make test-unit FILTER=StorageAccountantTests,ModelsFolderMoverTests,CleanupPlannerTests,RemoveEverythingTests
import AntiChatFoundation
@testable import AntiChatPlatform
import AntiChatStorage
import CryptoKit
import Foundation
import GRDB
import Security
import Testing

enum StorageFixture {
    struct Tree {
        var root: URL
        var paths: DataPaths
        var db: AppDatabase
        var blobs: [String: Int]  // sha → bytes
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// A container with a DB, backups, media (2 project files), caches, logs and a Models folder with 3 installs:
    /// chat (2 blobs), voice (1 blob + the chat tokenizer: shared), evil chat (1 blob) + an orphan blob + a partial.
    static func make(_ name: String = UUID().uuidString) throws -> Tree {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("storage-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let container = home.appendingPathComponent("Library/Application Support/AntiChat-Dev", isDirectory: true)
        let paths = DataPaths(bundleID: "app.antichat.AntiChat.test-\(name)", home: home, container: container,
                              caches: home.appendingPathComponent("Library/Caches/AntiChat"),
                              logs: home.appendingPathComponent("Library/Logs/AntiChat-Dev"),
                              models: container.appendingPathComponent("Models"), tmp: home.appendingPathComponent("tmp"))
        let fm = FileManager.default
        for d in [paths.caches, paths.logs, paths.tmp, container.appendingPathComponent("Backups"), container.appendingPathComponent("Media/2026")] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let db = try AppDatabase.onDisk(at: container.appendingPathComponent("antichat.sqlite"))
        func write(_ u: URL, _ n: Int, _ byte: UInt8 = 7) throws {
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: byte, count: n).write(to: u)
        }
        try write(container.appendingPathComponent("Backups/daily-20261101.sqlite"), 300_000)
        for i in 0..<9 { try write(container.appendingPathComponent("Backups/daily-202610\(10 + i).sqlite"), 50_000, UInt8(i)) }
        for i in 0..<6 { try write(container.appendingPathComponent("Media/2026/m\(i).png"), 400_000, UInt8(i)) }
        try write(container.appendingPathComponent("Catalog/catalog.json"), 20_000)
        try write(paths.caches.appendingPathComponent("router/proto.bin"), 120_000)
        try write(paths.caches.appendingPathComponent("metal-shaders/a.bin"), 60_000)
        try write(paths.logs.appendingPathComponent("app/app.log"), 30_000)
        try write(paths.logs.appendingPathComponent("app/app.log.1"), 30_000)
        try write(home.appendingPathComponent("Library/Preferences/\(paths.bundleID).plist"), 4_000)
        try write(paths.tmp.appendingPathComponent("AntiChat-incognito-x/a.txt"), 4_000)
        try write(home.appendingPathComponent("Library/Logs/DiagnosticReports/AntiChat-2026-11-05.ips"), 8_000)
        try write(home.appendingPathComponent("Library/Logs/DiagnosticReports/Other-2026.ips"), 8_000)  // not ours

        // Models: blobs by content hash, install views as relative symlinks, manifests.
        let models = ModelsDirectory(root: paths.models)
        try models.create()
        var blobs: [String: Int] = [:]
        func blob(_ n: Int, _ b: UInt8) throws -> String {
            let d = Data(repeating: b, count: n)
            let s = sha(d)
            let u = BlobStore(models: models).url(s)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: u)
            blobs[s] = n
            return s
        }
        let w1 = try blob(2_000_000, 1), tok = try blob(300_000, 2), v1 = try blob(900_000, 3), e1 = try blob(1_500_000, 4)
        _ = try blob(700_000, 5)  // orphan
        try write(models.part(String(repeating: "a", count: 64)), 250_000)
        func install(_ id: String, _ files: [String: String], slot: String) throws {
            let view = models.install(id)
            try fm.createDirectory(at: view, withIntermediateDirectories: true)
            for (name, s) in files {
                try fm.createSymbolicLink(atPath: view.appendingPathComponent(name).path,
                                          withDestinationPath: "../../store/sha256/\(s.prefix(2))/\(s)")
            }
            let obj: [String: Any] = ["model_id": id, "catalog_version": 1, "engine": "mlx", "placement": "symlink", "files": files,
                                      "sizes": files.mapValues { blobs[$0] ?? 0 }, "raw_tensor_files": [String]()]
            let m = try JSONDecoder().decode(InstallManifest.self, from: JSONSerialization.data(withJSONObject: obj))
            try m.encoded().write(to: view.appendingPathComponent("manifest.json"))
            try fm.createDirectory(at: models.manifests, withIntermediateDirectories: true)
            try m.encoded().write(to: models.manifest(m.sha256))
            try db.write { d in
                try d.execute(sql: "INSERT INTO model_install (slot, catalog_entry_id, manifest_sha, state) VALUES (?, ?, ?, 'ready')",
                              arguments: [slot, id, m.sha256])
            }
        }
        try install("chat-0.8b", ["model.safetensors": w1, "tokenizer.json": tok], slot: "chat/normal/chat_fast")
        try install("stt", ["model.bin": v1, "tokenizer.json": tok], slot: "voice/normal/stt")
        try install("evil-9b", ["model.safetensors": e1], slot: "chat/evil/chat")
        // Two Media files belong to a project (copied) → Chats & projects.
        try db.write { d in
            try d.execute(sql: "INSERT INTO project (id, name, created_at, updated_at) VALUES ('p', 'P', 0, 0)")
            for i in 0..<2 {
                let path = container.appendingPathComponent("Media/2026/m\(i).png").path
                try d.execute(sql: "INSERT INTO file_blob (id, sha256, size, path, created_at, origin) VALUES (?, ?, 400000, ?, 0, 'upload')",
                              arguments: ["b\(i)", "s\(i)", path])
                try d.execute(sql: """
                    INSERT INTO project_file (id, project_id, blob_id, display_name, size, origin, created_at)
                    VALUES (?, 'p', ?, 'f', 400000, 'copied', 0)
                    """, arguments: ["f\(i)", "b\(i)"])
            }
        }
        return Tree(root: root, paths: paths, db: db, blobs: blobs)
    }

    /// `du -sk` × 1024 over `urls` (one run, so hard links count once as in the accountant).
    static func du(_ urls: [URL]) -> Int64 {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return 0 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-skc"] + existing.map(\.path)
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let last = String(decoding: d, as: UTF8.self).split(separator: "\n").last ?? ""
        return (Int64(last.split(separator: "\t").first ?? "0") ?? 0) * 1024
    }
}

@Suite("StorageAccountantTests", .serialized) struct StorageAccountantTests {
    @Test func eightCategoriesSharedOnceAndMatchesDu() throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let r = StorageAccountant.measure(t.paths, database: t.db)
        #expect(Set(r.bytes.keys).isSubset(of: Set(StorageCategory.allCases)))
        #expect(StorageCategory.allCases.count == 8)
        // Model rows: the shared tokenizer counts once (first slot by order: chat), the voice row is flagged shared.
        let chat = try #require(r.models.first { $0.modelID == "chat-0.8b" })
        let voice = try #require(r.models.first { $0.modelID == "stt" })
        let evil = try #require(r.models.first { $0.modelID == "evil-9b" })
        #expect(!chat.shared && voice.shared && chat.category == .chatModels && voice.category == .voice && evil.category == .evil)
        func near(_ a: Int64, _ b: Int) -> Bool { abs(Double(a) - Double(b)) <= Double(b) * 0.05 + 8192 }
        #expect(near(chat.bytes, 2_300_000) && near(voice.bytes, 900_000) && near(evil.bytes, 1_500_000))
        // Project files (2 × 400 KB) are Chats & projects; the other 4 Media files the Media library.
        #expect(near(r.bytes[.media] ?? 0, 1_600_000))
        #expect((r.bytes[.chats] ?? 0) >= 800_000 + 750_000)
        // Orphan blob + partial + caches + logs + catalog land in Caches & logs (never "Other").
        #expect((r.bytes[.caches] ?? 0) >= 700_000 + 250_000 + 180_000)
        // AT-NFR-D8: every category sum and the total within 1 % of du over the same paths.
        let du = StorageFixture.du(t.paths.existing())
        #expect(abs(Double(r.total - du)) <= Double(du) * 0.01, "accountant \(r.total) vs du \(du)")
        let modelsDu = StorageFixture.du([t.paths.models.appendingPathComponent("store")])
        let modelSum = (r.bytes[.chatModels] ?? 0) + (r.bytes[.voice] ?? 0) + (r.bytes[.evil] ?? 0)
        #expect(abs(Double(modelSum - modelsDu + 700_000)) <= Double(modelsDu) * 0.02 + 16384, "models \(modelSum) du \(modelsDu)")
        // The CLI's JSON carries all eight + total.
        let json = try JSONSerialization.jsonObject(with: r.json()) as? [String: Int64]
        #expect(json?.count == 9)
    }

    /// VQ (S-21 Storage, NFR-D8): install views with no `model_install` row (no DB) are counted under the pack the
    /// hints name (Settings › Capabilities' facts), never as Caches & logs; an unknown view still is.
    @Test func installHintsWithoutRowsCountUnderTheirPack() throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let bare = StorageAccountant.measure(t.paths, reader: nil)
        #expect((bare.bytes[.chatModels] ?? 0) == 0)
        let r = StorageAccountant.measure(t.paths, reader: nil, installs: [
            "chat-0.8b": StorageInstallHint(pack: "chat", mode: "normal"),
            "stt": StorageInstallHint(pack: "voice", mode: "normal"),
        ])
        func near(_ a: Int64, _ b: Int) -> Bool { abs(Double(a) - Double(b)) <= Double(b) * 0.05 + 8192 }
        #expect(near(r.bytes[.chatModels] ?? 0, 2_300_000) && near(r.bytes[.voice] ?? 0, 900_000))
        #expect(r.models.contains { $0.modelID == "chat-0.8b" && $0.category == .chatModels })
        #expect(!r.models.contains { $0.modelID == "evil-9b" })  // no row, no hint → Caches & logs
        #expect(r.total == bare.total)  // the same files, only grouped differently
    }

    /// r66 F1: install views are links. A view whose links resolve outside the Models folder (a store reached through
    /// a link, a shared one) is counted at its real target — on the row and under its pack, once (two views, one
    /// target) — never as 0 KB; a link to a file that is gone is flagged missing; a hint's role reaches the row.
    @Test func linkedTargetsOutsideTheStoreCountOnceAndMissingIsFlagged() throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let fm = FileManager.default
        let models = ModelsDirectory(root: t.paths.models)
        let elsewhere = t.root.appendingPathComponent("shared-store/sha256", isDirectory: true)
        let big = Data(repeating: 9, count: 3_000_000), sha = StorageFixture.sha(big)
        let target = elsewhere.appendingPathComponent("\(sha.prefix(2))/\(sha)")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try big.write(to: target)
        for id in ["embed", "embed-copy"] {
            try fm.createDirectory(at: models.install(id), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: models.install(id).appendingPathComponent("model.safetensors").path,
                                      withDestinationPath: target.path)
        }
        let gone = String(repeating: "b", count: 64)
        try fm.createDirectory(at: models.install("chat-4b"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: models.install("chat-4b").appendingPathComponent("model.safetensors").path,
                                  withDestinationPath: "../../store/sha256/bb/\(gone)")
        let before = StorageAccountant.measure(t.paths, database: t.db)
        let r = StorageAccountant.measure(t.paths, database: t.db, installs: [
            "embed": StorageInstallHint(pack: "chat", mode: "normal", role: "embed"),
            "embed-copy": StorageInstallHint(pack: "chat", mode: "normal", role: "embed"),
            "chat-4b": StorageInstallHint(pack: "chat", mode: "normal", role: "chat"),
        ])
        func near(_ a: Int64, _ b: Int) -> Bool { abs(Double(a) - Double(b)) <= Double(b) * 0.05 + 8192 }
        let embed = try #require(r.models.first { $0.modelID == "embed" })
        let copy = try #require(r.models.first { $0.modelID == "embed-copy" })
        let chat4 = try #require(r.models.first { $0.modelID == "chat-4b" })
        #expect(near(embed.bytes, 3_000_000) && embed.role == "embed" && embed.pack == "chat" && !embed.missing)
        #expect(copy.bytes == 0 && copy.shared)  // the same file: counted once
        #expect(chat4.bytes == 0 && chat4.missing && !embed.missing)
        #expect(near((r.bytes[.chatModels] ?? 0) - (before.bytes[.chatModels] ?? 0), 3_000_000))
        #expect(near(r.total - before.total, 3_000_000))  // not also under Caches & logs
        #expect(near((r.locations[.models] ?? 0) - (before.locations[.models] ?? 0), 3_000_000))
    }

    @Test func globsAndPathsList() {
        #expect(DataPaths.matches("AntiChat-2026.ips", "AntiChat*.ips"))
        #expect(!DataPaths.matches("Other.ips", "AntiChat*.ips"))
        #expect(DataPaths.matches("AntiChat-incognito-abc", "AntiChat-incognito-*"))
        #expect(DataPaths.matches("app.antichat.AntiChat", "app.antichat.AntiChat*"))
        let p = DataPaths.current(environment: [:], options: LaunchOptions.parse([]), debug: false, defaults: UserDefaults.inMemory())
        let kinds = p.entries.map(\.kind)
        for k in [DataPaths.Kind.container, .caches, .logs, .preferences, .savedState, .httpStorages, .webKit, .fileToolsContainers,
                  .crashReports, .incognitoTemp] { #expect(kinds.contains(k)) }
        #expect(p.container.path.hasSuffix("Library/Application Support/AntiChat"))
        #expect(p.modelsAreInsideContainer && !kinds.contains(.models))
        // Debug: its own logs folder plus `Logs/AntiChat` (the vendored crash-reason log), unless the Release app's
        // data is on this Mac (then that folder is the Release app's).
        var d = DataPaths.current(environment: [:], options: LaunchOptions.parse([]), debug: true, defaults: UserDefaults.inMemory())
        d.keepsReleaseShared = false
        let logs = d.entries.filter { $0.kind == .logs }.map(\.url.lastPathComponent)
        #expect(logs == ["AntiChat-Dev", "AntiChat"])
        d.keepsReleaseShared = true
        #expect(d.entries.filter { $0.kind == .logs }.map(\.url.lastPathComponent) == ["AntiChat-Dev"])
        // M10.T09: the Debug build's helpers keep the shipped ids; their caches folder is listed (not when the Release
        // app's data is on this Mac: then it is the Release app's). Release covers it with `app.antichat.AntiChat*`.
        let helperCaches = { (x: DataPaths) in
            x.entries.contains { $0.kind == .bundleCaches && $0.pattern == "app.antichat.AntiChat.Engine*" }
        }
        #expect(!helperCaches(d))
        d.keepsReleaseShared = false
        #expect(helperCaches(d))
        #expect(!helperCaches(p))
        #expect(DataPaths.matches("app.antichat.AntiChat.Engine", "app.antichat.AntiChat.Engine*"))
    }
}

@Suite("CleanupPlannerTests", .serialized) struct CleanupPlannerTests {
    @Test func nothingDeletedBeforeConfirmOnlyCheckedAfter() throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let before = StorageFixture.du([t.root])
        let old = Date().addingTimeInterval(-100 * 86_400)
        for i in 0..<6 {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: t.paths.container.appendingPathComponent("Media/2026/m\(i).png").path)
        }
        let items = CleanupPlanner.plan(t.paths, database: t.db, modelLoaded: true)
        #expect(StorageFixture.du([t.root]) == before, "plan deletes nothing")
        let kinds = Dictionary(uniqueKeysWithValues: items.map { ($0.kind, $0) })
        #expect(kinds[.caches]?.files.contains { $0.lastPathComponent.contains("metal") } == false, "shader cache kept while a model is loaded")
        #expect(kinds[.oldLogs]?.files.map(\.lastPathComponent) == ["app.log.1"])
        #expect(kinds[.oldMedia]?.files.count == 4 && kinds[.oldMedia]?.defaultChecked == false, "project files kept; unchecked by default")
        #expect(kinds[.oldBackups]?.files.count == 3)  // 10 daily, keep 7
        #expect(kinds[.orphanBlobs]?.files.count == 1)
        #expect(kinds[.partialDownloads]?.files.count == 1)
        let freed = CleanupPlanner.execute(items, checked: [.orphanBlobs, .oldLogs])
        #expect(freed >= 700_000)
        for i in items {
            let gone = i.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
            #expect(gone == [.orphanBlobs, .oldLogs].contains(i.kind), "\(i.kind)")
        }
        // The installed models still verify.
        let r = StorageAccountant.measure(t.paths, database: t.db)
        #expect(r.models.count == 3)
    }
}

extension CleanupPlannerTests {
    // Release review: "Clean up" never offers (nor deletes) a blob a live view links to, even with no manifest and no
    // slot; files still needed by an open job are kept; and execute re-marks at delete time.
    @Test func orphanBlobsNeverIncludeLinkedOrRetainedBlobs() throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let fm = FileManager.default
        let models = ModelsDirectory(root: t.paths.models)
        try fm.removeItem(at: models.install("evil-9b").appendingPathComponent("manifest.json"))
        try fm.removeItem(at: models.manifests)
        try t.db.write { try $0.execute(sql: "DELETE FROM model_install") }
        let orphan = t.blobs.first { $0.value == 700_000 }!.key
        let items = CleanupPlanner.plan(t.paths, database: t.db, modelLoaded: true)
        let offered = Set(items.first { $0.kind == .orphanBlobs }?.files.map(\.lastPathComponent) ?? [])
        #expect(offered == [orphan], "only the real orphan: \(offered)")
        // An open download now needs the orphan: execute (re-marked) keeps it.
        let freed = CleanupPlanner.execute(items, checked: [.orphanBlobs], paths: t.paths, database: t.db, active: [orphan])
        #expect(freed == 0)
        #expect(BlobStore(models: models).contains(orphan))
        // A view written after the plan (an install finished while the sheet was open) keeps it too.
        try FilePlacement.symlink.place(BlobStore(models: models).url(orphan), at: models.install("late").appendingPathComponent("w.bin"))
        #expect(CleanupPlanner.execute(items, checked: [.orphanBlobs], paths: t.paths, database: t.db) == 0)
        for id in ["chat-0.8b", "stt", "evil-9b", "late"] {
            for name in try fm.contentsOfDirectory(atPath: models.install(id).path) where name != "manifest.json" {
                #expect(fm.fileExists(atPath: models.install(id).appendingPathComponent(name).path), "\(id)/\(name) resolves")
            }
        }
        // With `active` at plan time, the retained blob is not offered at all.
        let again = CleanupPlanner.plan(t.paths, database: t.db, active: [orphan])
        #expect(again.first { $0.kind == .orphanBlobs } == nil)
    }
}

@Suite("ModelsFolderMoverTests", .serialized) struct ModelsFolderMoverTests {
    func defaults() -> UserDefaults { UserDefaults.inMemory() }

    @Test func moveVerifiesKeepsStarterAndPersistsBookmark() async throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let dest = t.root.appendingPathComponent("ExternalDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let d = defaults()
        let loc = ModelsFolderLocation(defaults: d)
        var mover = ModelsFolderMover(source: ModelsDirectory(root: t.paths.models), internalRoot: t.paths.modelsInternal)
        mover.reserveBytes = 0
        let r = try mover.move(to: dest, location: loc)
        let moved = dest.appendingPathComponent("Models")
        #expect(r.verifiedBlobs == t.blobs.count)
        for (sha, _) in t.blobs {
            let u = BlobStore(models: ModelsDirectory(root: moved)).url(sha)
            #expect(StorageFixture.sha(try Data(contentsOf: u)) == sha)
        }
        #expect(!FileManager.default.fileExists(atPath: t.paths.models.path), "old copies deleted")
        // The starter stays internal and its view resolves there.
        let starter = ModelsDirectory(root: t.paths.modelsInternal).install("chat-0.8b").appendingPathComponent("model.safetensors")
        #expect(FileManager.default.fileExists(atPath: starter.path))
        // NFR-D9; the flag is eventually consistent (BackupExclusionTests), so wait for it rather than read once.
        try await until(5) { ModelsDirectory(root: moved).isExcludedFromBackup }
        #expect(ModelsDirectory(root: moved).isExcludedFromBackup, "NFR-D9")
        // Bookmark survives a "relaunch" (a fresh resolver over the same defaults) and DataPaths follows it.
        #expect(ModelsFolderLocation(defaults: d).resolve() == .moved(moved.standardizedFileURL) ||
                ModelsFolderLocation(defaults: d).resolve().movedURL?.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())
        // Drive gone → missing (+ starter fallback path); back → resumes.
        // (A bookmark follows a rename on the same volume, so "unplug" = the folder is gone, then comes back.)
        let parked = t.root.appendingPathComponent("parked")
        try FileManager.default.copyItem(at: moved, to: parked)
        try FileManager.default.removeItem(at: moved)
        #expect(ModelsFolderLocation(defaults: d).resolve().isMissing)
        try FileManager.default.moveItem(at: parked, to: moved)
        #expect(ModelsFolderLocation(defaults: d).resolve().movedURL != nil)
    }

    /// RC review P2-5: a destination inside the current Models folder is refused (it would go with the old copies).
    @Test func destinationInsideSourceIsRefused() throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let inside = t.paths.models.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        var mover = ModelsFolderMover(source: ModelsDirectory(root: t.paths.models), internalRoot: t.paths.modelsInternal)
        mover.reserveBytes = 0
        #expect(throws: ModelsFolderMoveError.destinationNotEmpty) {
            try mover.move(to: inside, location: ModelsFolderLocation(defaults: defaults()))
        }
        for (sha, _) in t.blobs {
            #expect(FileManager.default.fileExists(atPath: BlobStore(models: ModelsDirectory(root: t.paths.models)).url(sha).path))
        }
    }

    @Test func failureMidCopyLeavesOldFolderIntact() throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        let before = StorageAccountant.measure(t.paths, database: t.db)
        let dest = t.root.appendingPathComponent("Drive2", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let d = defaults()
        var mover = ModelsFolderMover(source: ModelsDirectory(root: t.paths.models), internalRoot: t.paths.modelsInternal)
        mover.reserveBytes = 0
        mover.failAfterFiles = 3
        #expect(throws: ModelsFolderMoveError.self) { try mover.move(to: dest, location: ModelsFolderLocation(defaults: d)) }
        #expect(!FileManager.default.fileExists(atPath: dest.appendingPathComponent("Models").path), "partial copy deleted")
        #expect(ModelsFolderLocation(defaults: d).resolve() == .standard, "no bookmark")
        let after = StorageAccountant.measure(t.paths, database: t.db)
        #expect(after.models == before.models)
        // Not enough space → refused before copying.
        var greedy = ModelsFolderMover(source: ModelsDirectory(root: t.paths.models), internalRoot: t.paths.modelsInternal)
        greedy.reserveBytes = Int64.max / 4
        #expect(throws: ModelsFolderMoveError.self) { try greedy.move(to: dest, location: ModelsFolderLocation(defaults: d)) }
    }
}

@Suite("RemoveEverythingTests", .serialized) struct RemoveEverythingTests {
    @Test func zeroFilesKeychainAndHooksInOrder() async throws {
        let t = try StorageFixture.make()
        defer { try? FileManager.default.removeItem(at: t.root) }
        // A moved Models folder outside the container must go too.
        var paths = t.paths
        let external = t.root.appendingPathComponent("Ext/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: t.paths.models, to: external)
        paths.models = external
        let prefix = "app.antichat.test-\(UUID().uuidString)."
        for s in ["mcp.a", "mcp.b"] {
            let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: prefix + s,
                                      kSecAttrAccount as String: "token", kSecValueData as String: Data("x".utf8)]
            #expect(SecItemAdd(add as CFDictionary, nil) == errSecSuccess)
        }
        #expect(KeychainInventory.services(prefix: prefix).count == 2)
        let order = OrderLog()
        var hooks = RemovalHooks()
        hooks.cancelJobs = { order.add("cancel") }
        hooks.stopEngine = { order.add("stop") }
        hooks.relayForget = { order.add("relay"); return "skipped: Offline only" }
        hooks.unregisterLoginItem = { order.add("login") }
        hooks.resetShortcuts = { order.add("shortcuts") }
        var svc = RemoveEverythingService(paths: paths, hooks: hooks)
        svc.keychainPrefix = prefix
        svc.defaultsDomain = "app.antichat.test-remove-\(UUID().uuidString)"
        let plan = svc.plan()
        #expect(plan.first == external, "the moved Models folder is in the plan")
        #expect(plan.allSatisfy { $0.path.hasPrefix(t.root.path) }, "never a path outside DataPaths")
        #expect(!plan.contains { $0.lastPathComponent == "Other-2026.ips" })
        let r = await svc.run()
        #expect(r.leftovers.isEmpty && r.keychainLeft.isEmpty && r.relayNote == "skipped: Offline only")
        #expect(order.items == ["cancel", "stop", "relay", "login", "shortcuts"])
        #expect(paths.existing().isEmpty, "zero files in the documented paths")
        #expect(FileManager.default.fileExists(atPath: t.paths.home.appendingPathComponent("Library/Logs/DiagnosticReports/Other-2026.ips").path))
    }
}

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.withLock { list.append(s) } }
    var items: [String] { lock.withLock { list } }
}
