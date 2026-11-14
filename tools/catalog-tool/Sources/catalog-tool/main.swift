// M2.T04 (R-220, R-300; P-platform-02): `catalog-tool {keygen,build,lint,sign,fixtures}`. Run via `make catalog`.
//   keygen   --out <prefix>
//   build    --models catalog/models.yaml --assign catalog/assignments.yaml --out build/catalog/catalog.json
//            [--search-engines catalog/search-engines.yaml] [--mcp-curated catalog/mcp-curated.yaml]
//            [--lock catalog/catalog.lock.json] [--previous site/public/catalog/v2/catalog.json] [--check]
//   lint     <catalog.json> [--lock catalog/catalog.lock.json]
//   sign     <file> --key-file <priv> [--cryptokit] [--out <sig>]
//   fixtures --from <catalog.json> --out <dir> --key-file <priv>
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
var args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i); return true
}
func url(_ p: String) -> URL { URL(fileURLWithPath: p, relativeTo: root).standardizedFileURL }
func loadLock(_ p: String) -> Lock? { (try? Data(contentsOf: url(p))).flatMap { try? JSONDecoder().decode(Lock.self, from: $0) } }
func lockData(_ l: Lock) throws -> Data { try Manifest.encoder().encode(l) + Data("\n".utf8) }

do {
    guard let command = args.first else { throw ToolError.message("usage: catalog-tool keygen|build|lint|sign|fixtures …") }
    args.removeFirst()
    switch command {
    case "keygen":
        try Keygen.run(prefix: option("--out") ?? "catalog")
    case "build":
        let modelsPath = option("--models") ?? "catalog/models.yaml"
        let assignPath = option("--assign") ?? "catalog/assignments.yaml"
        let outPath = option("--out") ?? "build/catalog/catalog.json"
        let lockPath = option("--lock") ?? "catalog/catalog.lock.json"
        let previousPath = option("--previous") ?? "site/public/catalog/v2/catalog.json"
        let runtimesPath = option("--runtimes") ?? "catalog/runtimes.yaml"
        let enginesPath = option("--search-engines") ?? "catalog/search-engines.yaml"  // M7.T01 (R-253)
        let curatedPath = option("--mcp-curated") ?? "catalog/mcp-curated.yaml"  // M7.T06 (R-081 AC4)
        let check = flag("--check")
        let specs = try Spec.models(url(modelsPath))
        let old = loadLock(lockPath)
        let lock = try await Build.resolve(specs, hub: AnonymousHub(), lock: check ? nil : old)
        if check {
            guard let old else { throw ToolError.message("check: \(lockPath) missing") }
            var drift: [String] = []
            for k in Set(old.models.keys).union(lock.models.keys).sorted() where old.models[k] != lock.models[k] {
                let o = old.models[k], n = lock.models[k]
                let detail = zip(o?.files ?? [], n?.files ?? []).first { $0 != $1 }.map { " (\($0.0.path))" } ?? ""
                drift.append("\(k)\(detail)")
            }
            for k in lock.models.keys.sorted() { print("check: \(k) gated:false files:\(lock.models[k]!.files.count)") }
            if !drift.isEmpty { throw ToolError.message("check: lockfile drift: \(drift.joined(separator: ", "))") }
            print("check: \(lock.models.count) keys match \(lockPath); none gated")
        } else {
            try lockData(lock).write(to: url(lockPath))
            let previous = try? Manifest.load(url(previousPath))
            let m = try Build.manifest(specs: specs, lock: lock, assignmentsURL: url(assignPath), issued: Date(), previous: previous,
                                       searchEnginesURL: url(enginesPath), mcpCuratedURL: url(curatedPath),
                                       runtimes: try Spec.runtimes(url(runtimesPath)))
            try FileManager.default.createDirectory(at: url(outPath).deletingLastPathComponent(), withIntermediateDirectories: true)
            try m.encoded().write(to: url(outPath))
            print("build: catalog_version \(m.catalog_version), \(m.models.count) models → \(outPath)")
        }
    case "lint":
        guard let path = args.first else { throw ToolError.message("lint: catalog path missing") }
        let lockPath = option("--lock") ?? "catalog/catalog.lock.json"
        let m = try Manifest.load(url(path))
        let gated = (loadLock(lockPath)?.models ?? [:]).mapValues(\.gated)
        let errors = Lint.run(m, gated: gated)
        for e in errors { print("lint: \(e)") }
        if !errors.isEmpty { throw ToolError.message("lint: \(errors.count) error(s)") }
        for (k, e) in m.models.sorted(by: { $0.key < $1.key }) {
            print("lint: \(k) gated:\(gated[k].map(String.init) ?? "?") license:\(e.license ?? "-") notice:\(e.modification_notice ?? "-")")
        }
        print("lint: ok (\(m.models.count) models)")
    case "sign":
        let keyFile = option("--key-file") ?? "fixtures/catalog/test-keys/catalog-a.priv"
        let out = option("--out").map(url)
        let cryptokit = flag("--cryptokit")
        guard let path = args.first else { throw ToolError.message("sign: file missing") }
        let b64 = try Sign.run(file: url(path), keyFile: url(keyFile).path, signUpdate: cryptokit ? nil : Sign.defaultSignUpdate(root: root), out: out)
        print("sign: \(path).sig \(b64.prefix(16))…")
    case "fixtures":
        let from = option("--from") ?? "build/catalog/catalog.json"
        let out = option("--out") ?? "fixtures/catalog"
        let keyFile = option("--key-file") ?? "fixtures/catalog/test-keys/catalog-a.priv"
        try Fixtures.run(from: Manifest.load(url(from)), out: url(out), keyFile: url(keyFile).path, signUpdate: Sign.defaultSignUpdate(root: root))
    default:
        throw ToolError.message("unknown command \(command)")
    }
} catch {
    FileHandle.standardError.write(Data("catalog-tool: \(error)\n".utf8))
    exit(1)
}
