// M2.T10 step 7 (R-293, NFR-S5, NFR-SEC2 load-time half): before a view is handed to an engine, every file's size is
// compared with the manifest (fast) and files changed since the last verify (mtime after `.verified`) are re-hashed;
// a missing, short or altered file refuses the load with `model.corrupt` (+ [Re-download ({size})]) instead of crashing
// anything. A view naming a pickle / Python file (NFR-SEC2) is refused the same way, whatever the catalog said.
// `Repair.run` re-hashes, deletes only the bad blobs, re-fetches them through the DownloadCoordinator and rebuilds the view.
import AntiChatFoundation
import Darwin
import Foundation

public enum Repair {
    public enum Problem: Sendable, Hashable {
        case missing(path: String, sha256: String)
        case size(path: String, sha256: String)
        case digest(path: String, sha256: String)
        /// NFR-SEC2: not safetensors / GGUF / Core ML / ONNX (pickle or code) — never loaded, never "repaired".
        case forbidden(path: String)
        case noView

        public var sha256: String? {
            switch self {
            case .missing(_, let s), .size(_, let s), .digest(_, let s): s
            case .forbidden, .noView: nil
            }
        }
    }

    static func stamp(_ models: ModelsDirectory, _ id: String) -> URL { models.install(id).appending(path: ".verified") }

    /// The NFR-S5 check. `full` re-hashes every file (Repair, `antichat-cli models verify`).
    public static func check(_ id: String, models: ModelsDirectory, full: Bool = false) -> [Problem] {
        guard let m = InstallManifest.load(models.install(id).appending(path: "manifest.json")) else { return [.noView] }
        var out: [Problem] = []
        for p in m.files.keys.sorted() where CatalogModel.forbiddenFile(p, rawTensors: m.rawTensors) { out.append(.forbidden(path: p)) }
        let verifiedAt = (try? FileManager.default.attributesOfItem(atPath: stamp(models, id).path)[.modificationDate] as? Date) ?? .distantPast
        for (path, sha) in m.files.sorted(by: { $0.key < $1.key }) {
            let file = models.install(id).appending(path: path).resolvingSymlinksInPath()
            var st = stat()
            guard stat(file.path, &st) == 0 else { out.append(.missing(path: path, sha256: sha)); continue }
            if let want = m.sizes[path], Int64(st.st_size) != want { out.append(.size(path: path, sha256: sha)); continue }
            let mtime = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
            if full || mtime > verifiedAt, (try? Verify.sha256(file)) != sha { out.append(.digest(path: path, sha256: sha)) }
        }
        if out.isEmpty { FileManager.default.createFile(atPath: stamp(models, id).path, contents: nil) }  // touch
        return out
    }

    /// Load gate: the view's URL, or `model.corrupt` with the re-download size in `detail` (NFR-S5).
    public static func loadCheck(_ id: String, models: ModelsDirectory) -> Result<URL, AntiChatError> {
        let problems = check(id, models: models)
        guard !problems.isEmpty else { return .success(models.install(id)) }
        let bytes = redownloadBytes(problems, models: models, id: id)
        AppLog.log(.store, .error, "model \(id) refused at load: \(problems)")
        return .failure(AntiChatError(.modelCorrupt, detail: "redownload=\(bytes)"))
    }

    /// The {size} of "Re-download ({size})": the bad files only.
    public static func redownloadBytes(_ problems: [Problem], models: ModelsDirectory, id: String) -> Int64 {
        guard let m = InstallManifest.load(models.install(id).appending(path: "manifest.json")) else { return 0 }
        return problems.reduce(Int64(0)) { acc, p in
            switch p {
            case .missing(let path, _), .size(let path, _), .digest(let path, _): acc + (m.sizes[path] ?? 0)
            default: acc
            }
        }
    }

    /// Re-hashes `model`'s view, deletes the bad blobs, re-fetches only those and rebuilds the view. Returns what was
    /// wrong (empty = nothing to do). Forbidden files are not repairable and throw.
    @discardableResult
    public static func run(_ model: CatalogModel, catalogVersion: Int, coordinator: DownloadCoordinator) async throws -> [Problem] {
        let models = coordinator.models
        let problems = check(model.id, models: models, full: true)
        if problems.contains(where: { if case .forbidden = $0 { true } else { false } }) {
            throw AntiChatError(.modelCorrupt, detail: "NFR-SEC2 forbidden file in \(model.id)")
        }
        let bad = Set(problems.compactMap(\.sha256))
        let store = BlobStore(models: models)
        for sha in bad where store.contains(sha) { try store.remove(sha) }
        let missing = problems == [.noView] ? Set(model.files.map(\.sha256)).filter { !store.contains($0) } : bad
        var ids: [String] = []
        for f in model.files where missing.contains(f.sha256) {
            ids.append(await coordinator.enqueue(DownloadRequest(file: f, model: model, pack: "repair")).id)
        }
        for id in ids {
            let end = await coordinator.wait(id)
            guard end?.state == .done else { throw AntiChatError(.modelCorrupt, detail: "re-download failed: \(end?.errorKey ?? "?")") }
        }
        if !problems.isEmpty { try InstallView.materialize(model, catalogVersion: catalogVersion, models: models) }
        return problems
    }
}
