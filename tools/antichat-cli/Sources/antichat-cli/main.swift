// antichat-cli (M2.T08/T10): the store and download queue from the command line — tests, `make models-dev`, AT runs.
// Hand-rolled argument parsing (swift-argument-parser is not pinned). Every byte goes through NetworkGate (`.models`).
//
//   antichat-cli download --models <dir> --db <sqlite> --sha256 <hex> --size <n> --source <url>… [--chunk-mb n]
//                         [--lanes n] [--pack p]
//       one file through the DownloadCoordinator (restores the queue from --db first, so a relaunch after kill -9
//       resumes from the bitmap). Prints `done <blob path>`; exit 0 done, 3 failed (prints the error key), 4 paused.
//   antichat-cli models install --models <dir> [--db <sqlite>] [--catalog <json>] --id <model>… [--slot <s>]
//       download (deduplicated, verified) and materialise each model's install view; `--from-store` instead rebuilds
//       every view from its manifest (no network). `--catalog` = a local catalog JSON (dev/test; default: the bundled,
//       signed baseline).
//   antichat-cli models import --models <dir> --from <legacy dir> --id <model>… [--catalog <json>] [--db <sqlite>]
//       (M2.T12, A-M2-T10a (d)) reuse files already on disk: `<from>/<id>/<path>` whose size and sha256 match the
//       catalog are APFS-cloned into the store (no extra disk, no download); complete models get their install view.
//       Prints `imported <id> <n>/<total>`; exit 0 when every model is complete, 6 when some files are still missing.
//   antichat-cli models list [--json] · remove --id <m>… [--gc] · gc [--all] · verify [--id <m>] · rollback --slot <s>
//   antichat-cli models frees --id <m>…       the exact "frees X" in bytes (SpaceAccountant)
//   antichat-cli catalog sizes --tier <T0…T4> [--json]   default Normal download size per pack set (unique sha256)
//   antichat-cli index rebuild [--db <sqlite>]   (M2.T16) drop every search chunk (vectors follow) and chunk every
//       finished message again; the app embeds the pending chunks in the background. Prints `chunks <n>`.
//   antichat-cli db make-fixture --upto <identifier> --out <path> [--seed n] [--future]   (M8.T01, DEBUG) a fixture
//       database migrated up to <identifier> and seeded deterministically; `--future` adds `v999_future`.
//   antichat-cli db migrate --db <sqlite>   (M8.T01) open through MigrationRunner; prints the outcome and backup.
//   antichat-cli db identifiers   (M8.T01) this build's migration identifiers, in order.
//   antichat-cli storage --json [--container <dir>]   (M8.T10, DEBUG) StorageAccountant over a container (default
//       ANTICHAT_DEV_CONTAINER, else the Debug container; ANTICHAT_ROOT honoured): `{category: bytes, total, paths}`.
//       The DB is read from a copy, so nothing in the container changes.
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatPlatform
import AntiChatStorage
import Foundation
import GRDB

struct Args {
    var command: [String] = []
    var opts: [String: [String]] = [:]
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let k = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { opts[k, default: []].append(argv[i + 1]); i += 2 } else { opts[k, default: []].append("1"); i += 1 }
            } else { command.append(a); i += 1 }
        }
    }
    func one(_ k: String) -> String? { opts[k]?.last }
    func need(_ k: String) -> String {
        guard let v = one(k) else { fail("missing --\(k)") }
        return v
    }
}

func fail(_ msg: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("antichat-cli: \(msg)\n".utf8))
    exit(code)
}

func download(_ a: Args) async throws -> Int32 {
    let models = ModelsDirectory(root: URL(fileURLWithPath: a.need("models")))
    try models.create()
    let db = try AppDatabase.onDisk(at: URL(fileURLWithPath: a.need("db")))
    let chunk = Int64(a.one("chunk-mb") ?? "64").map { $0 * TransferConfig.mib } ?? 64 * TransferConfig.mib
    let config = TransferConfig(lanes: Int(a.one("lanes") ?? "4") ?? 4, chunkSize: chunk)
    let dl = DownloadCoordinator(models: models, database: db, config: config)
    try await dl.restore()
    let sha = a.need("sha256")
    guard let size = Int64(a.need("size")) else { fail("bad --size") }
    let sources = (a.opts["source"] ?? []).compactMap(URL.init(string:))
    let job: DownloadJob
    if let j = await dl.job(sha256: sha) { job = j } else {
        job = await dl.enqueue(DownloadRequest(sha256: sha, size: size, sources: sources, pack: a.one("pack") ?? "chat"))
    }
    if job.state == .paused || job.state == .failed { await dl.resume(job.id) }
    guard let end = await dl.wait(job.id) else { fail("no job") }
    switch end.state {
    case .done:
        print("done \(dl.blobs.url(sha).path)")
        return 0
    case .paused: print("paused \(end.errorKey ?? "")"); return 4
    default: print("failed \(end.errorKey ?? "download.failed")"); return 3
    }
}

func catalog(_ a: Args) throws -> ModelCatalog {
    if let p = a.one("catalog") { return try ModelCatalog.decode(Data(contentsOf: URL(fileURLWithPath: p))) }
    guard let b = CatalogStore.bundledBaseline() else { fail("no bundled catalog") }
    return try ModelCatalog.decode(b.data)
}

func json(_ v: Any) {
    let d = try! JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: d, as: UTF8.self))
}

func models(_ a: Args) async throws -> Int32 {
    let dir = ModelsDirectory(root: URL(fileURLWithPath: a.need("models")))
    try dir.create()
    let db = try a.one("db").map { try AppDatabase.onDisk(at: URL(fileURLWithPath: $0)) }
    let sub = a.command.dropFirst().first ?? ""
    let ids = a.opts["id"] ?? []
    switch sub {
    case "install":
        if a.one("from-store") != nil {
            for m in dir.installedManifests() { try InstallView.rematerialize(m, models: dir) }
            print("rematerialised \(dir.installedManifests().count)")
            return 0
        }
        let cat = try catalog(a)
        let dl = DownloadCoordinator(models: dir, database: db)
        try await dl.restore()
        for id in ids {
            guard let m = cat.models[id] else { fail("unknown model \(id)") }
            for j in await dl.enqueue(model: m, pack: a.one("pack") ?? "chat") where j.state != .done {  // present blobs: done
                let end = await dl.wait(j.id)
                guard end?.state == .done else { print("failed \(id) \(end?.errorKey ?? "")"); return 3 }
            }
            try InstallView.materialize(m, catalogVersion: cat.catalogVersion, models: dir, database: db, slot: a.one("slot"))
            print("ready \(id)")
        }
        return 0
    case "import":
        guard let from = a.one("from") else { fail("import needs --from <legacy Models dir>") }
        let cat = try catalog(a)
        let store = BlobStore(models: dir)
        var incomplete = 0
        for id in ids {
            guard let m = cat.models[id] else { fail("unknown model \(id)") }
            var have = 0
            let root = URL(fileURLWithPath: from).appending(path: id)
            // Legacy dirs may nest a repo one level down (`turn/onnx/…`): any file whose path ends with the catalog path.
            let all = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
            for f in m.files {
                if store.contains(f.sha256) { have += 1; continue }
                let rel = all.first { $0 == f.path } ?? all.first { $0.hasSuffix("/" + f.path) } ?? f.path
                let src = root.appending(path: rel)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: src.path))?[.size] as? Int64, size == f.size,
                      (try? Verify.sha256(src)) == f.sha256 else { continue }
                let part = dir.part(f.sha256)
                try? FileManager.default.removeItem(at: part)
                try FilePlacement.clone.place(src.resolvingSymlinksInPath(), at: part)
                try store.commit(partial: part, sha256: f.sha256)
                have += 1
            }
            print("imported \(id) \(have)/\(m.files.count)")
            if have == m.files.count {
                try InstallView.materialize(m, catalogVersion: cat.catalogVersion, models: dir, database: db, slot: a.one("slot"))
            } else { incomplete += 1 }
        }
        return incomplete == 0 ? 0 : 6
    case "path":
        // The install view of a model (`make models-dev`, benches): prints `<Models>/installs/<id>`, exit 1 if absent.
        for id in ids {
            let u = dir.install(id)
            guard FileManager.default.fileExists(atPath: u.appending(path: "manifest.json").path) else { return 1 }
            print(u.path)
        }
        return 0
    case "list":
        let rows = dir.installedManifests().map { ["id": $0.modelID, "state": "ready", "files": $0.files.count, "catalog_version": $0.catalogVersion] as [String: Any] }
        if a.one("json") != nil { json(rows) } else { rows.forEach { print("\($0["id"]!) ready") } }
        return 0
    case "remove":
        for id in ids { try InstallView.remove(id, models: dir) }
        if a.one("gc") != nil { print("freed \(try GarbageCollector(models: dir, database: db).sweep().freedBytes)") }
        return 0
    case "gc":
        let r = try GarbageCollector(models: dir, database: db).sweep(all: a.one("all") != nil)
        print("removed \(r.removedBlobs.count) blobs, \(r.removedParts) parts, freed \(r.freedBytes)")
        return 0
    case "frees":
        print(SpaceAccountant.frees(Set(ids), models: dir))
        return 0
    case "verify":
        var bad = 0
        for m in dir.installedManifests() where ids.isEmpty || ids.contains(m.modelID) {
            let p = Repair.check(m.modelID, models: dir, full: true)
            print("\(m.modelID) \(p.isEmpty ? "ok" : "corrupt \(p)")")
            bad += p.isEmpty ? 0 : 1
        }
        return bad == 0 ? 0 : 5
    case "rollback":
        guard let db, let slot = a.one("slot") else { fail("rollback needs --db and --slot") }
        guard let rec = try await db.read({ try ModelInstallRecord.fetchOne($0, key: slot) }), let prev = rec.previousManifestSHA,
              let m = InstallManifest.load(dir.manifest(prev)) else { fail("no previous manifest for \(slot)") }
        guard m.blobs.allSatisfy(BlobStore(models: dir).contains) else { fail("previous blobs were collected") }
        try InstallView.rematerialize(m, models: dir)
        try await db.write { d in
            try ModelInstallRecord(slot: slot, catalogEntryID: m.modelID, manifestSHA: prev, state: "ready",
                                   previousManifestSHA: rec.manifestSHA, installedAt: Date()).save(d)
        }
        print("rolled back \(slot) to \(m.modelID)")
        return 0
    default:
        fail("usage: antichat-cli models install|import|path|list|remove|gc|frees|verify|rollback")
    }
}

func catalogCmd(_ a: Args) throws -> Int32 {
    guard a.command.dropFirst().first == "sizes", let t = a.one("tier").flatMap(LaunchOptions.Tier.init(rawValue:)) else {
        fail("usage: antichat-cli catalog sizes --tier T0…T4 [--json]")
    }
    var o = LaunchOptions()
    o.fakeHardware = t
    guard let profile = HardwareProbe.fixtureProfile(options: o) else { fail("no fixture for \(t)") }
    let cat = try catalog(a)
    let sel = ModelSelector(catalog: cat).select(profile: profile)
    var out: [String: Any] = ["tier": t.rawValue, "fixture": HardwareProbe.tierFixtures[t] ?? ""]
    for (name, packs) in [("chat", Set([ModelPack.chat])), ("all", Set(ModelPack.allCases))] as [(String, Set<ModelPack>)] {
        out[name] = DownloadSize.bytes(ids: sel.installIDs(packs: packs, modes: [.normal], onDemand: Set(cat.onDemand)), catalog: cat)
    }
    for p in ModelPack.allCases { out["pack." + p.rawValue] = DownloadSize.bytes(ids: sel.installIDs(packs: [p], modes: [.normal], onDemand: Set(cat.onDemand)), catalog: cat) }
    if a.one("json") != nil { json(out) } else { out.sorted { $0.key < $1.key }.forEach { print("\($0.key) \($0.value)") } }
    return 0
}

func indexCmd(_ a: Args) async throws -> Int32 {
    guard a.command.dropFirst().first == "rebuild" else { fail("usage: antichat-cli index rebuild [--db <sqlite>]") }
    let db = try a.one("db").map { try AppDatabase.onDisk(at: URL(fileURLWithPath: $0)) } ?? AppDatabase.openDefault()
    guard VecLoader.selfTest(db) else { fail("sqlite-vec self-test failed") }
    print("chunks \(try await BackgroundIndexer(database: db).rebuild())")
    return 0
}

func dbCmd(_ a: Args) throws -> Int32 {
    switch a.command.dropFirst().first {
    case "identifiers":
        Migrations.identifiers.forEach { print($0) }
        return 0
    case "migrate":
        guard let path = a.one("db") else { fail("usage: antichat-cli db migrate --db <sqlite>") }
        do {
            let (_, report) = try AppDatabase.open(at: URL(fileURLWithPath: path), runner: MigrationRunner(eraseOnSchemaChange: false))  // never erase
            print("ready from=\(report.applied.last ?? "new") to=\(report.head) backup=\(report.backup?.path ?? "none") ms=\(Int(report.durationMs))")
            return 0
        } catch StorageError.launchBlocked(let state) {
            print("blocked \(state)")
            return 7
        }
    #if DEBUG
    case "make-fixture":
        if let out = a.one("out"), a.one("legacy-m1") != nil {
            try DBFixtureMaker.makeLegacyM1(at: URL(fileURLWithPath: out))
            print("fixture \(out) legacy-m1")
            return 0
        }
        guard let upTo = a.one("upto"), let out = a.one("out") else {
            fail("usage: antichat-cli db make-fixture --upto <identifier> --out <path> [--seed n] [--future]")
        }
        try DBFixtureMaker.make(upTo: upTo, at: URL(fileURLWithPath: out), seed: UInt64(a.one("seed") ?? "") ?? 20_261_030,
                                future: a.one("future") != nil)
        print("fixture \(out) upto=\(upTo)")
        return 0
    #endif
    default: fail("usage: antichat-cli db identifiers | migrate --db <sqlite> | make-fixture --upto <id> --out <path>")
    }
}

#if DEBUG
func storageCmd(_ a: Args) throws -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let container = a.one("container") ?? env["ANTICHAT_DEV_CONTAINER"]
    let options = LaunchOptions.parse(container.map { ["-ANTICHAT_DEV_CONTAINER", $0] } ?? [])
    let paths = DataPaths.current(options: options, debug: true)
    let fm = FileManager.default
    var reader: DatabaseQueue?
    let db = paths.container.appendingPathComponent("antichat.sqlite")
    let tmp = fm.temporaryDirectory.appendingPathComponent("storage-cli-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmp) }
    if fm.fileExists(atPath: db.path) {
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for ext in ["", "-wal"] where fm.fileExists(atPath: db.path + ext) {
            try fm.copyItem(atPath: db.path + ext, toPath: tmp.appendingPathComponent("antichat.sqlite" + ext).path)
        }
        reader = try DatabaseQueue(path: tmp.appendingPathComponent("antichat.sqlite").path)
    }
    let r = StorageAccountant.measure(paths, reader: reader)
    var obj = (try JSONSerialization.jsonObject(with: r.json())) as? [String: Any] ?? [:]
    obj["paths"] = paths.existing().map(\.path)
    let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: out, as: UTF8.self))
    return 0
}
#endif

let args = Args(Array(CommandLine.arguments.dropFirst()))
let code: Int32
do {
    switch args.command.first {
    case "download": code = try await download(args)
    case "models": code = try await models(args)
    case "catalog": code = try catalogCmd(args)
    case "index": code = try await indexCmd(args)
    case "db": code = try dbCmd(args)
    #if DEBUG
    case "storage": code = try storageCmd(args)
    #endif
    default: fail("usage: antichat-cli download …")
    }
} catch {
    fail("\(error)", code: 1)
}
exit(code)
