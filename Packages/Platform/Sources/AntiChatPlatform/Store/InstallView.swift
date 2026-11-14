// M2.T10 steps 2–3 (R-293 AC2, NFR-D5; blueprint E §E.2.6): an install view is `installs/<model-id>/` — the files under
// the names the engine expects, each a relative symlink into the store (swift-huggingface@199277c HubCache snapshot
// layout) or, for engines that refuse symlinks, an APFS clone (no extra disk) — plus `manifest.json`. It is written
// in `<Models>/staging/<id>.tmp/` (same volume, outside `installs/`) and renamed into place, so `kill -9` at any point leaves no view or a complete one; the
// slot (`model_install`) flips only after the view exists, in one transaction.
import AntiChatStorage
import Darwin
import Foundation
import GRDB

public enum InstallViewError: Error, Equatable, Sendable {
    case missingBlob(path: String, sha256: String)
    case unsafePath(String)
}

public enum InstallView {
    /// Engines that load through symlinks (M0 spikes: the MLX loader and llama-server read a symlinked directory);
    /// the rest get clones (Core ML `.mlmodelc` bundles, sd.cpp, FastMetal, ONNX — P-platform-04 residual).
    public static func placement(engine: String) -> FilePlacement {
        ["mlx-swift-lm", "llama.cpp"].contains(engine) ? .symlink : .clone
    }

    /// Materialises `model` from the store (every blob must be present) and returns the view's URL.
    /// With `database` and `slot`, the `model_install` row flips to it (previous manifest kept for rollback).
    @discardableResult
    public static func materialize(_ model: CatalogModel, catalogVersion: Int, models: ModelsDirectory,
                                   database: AppDatabase? = nil, slot: String? = nil) throws -> URL {
        let fm = FileManager.default
        let store = BlobStore(models: models)
        let manifest = InstallManifest(model: model, catalogVersion: catalogVersion)
        for (path, sha) in manifest.files {
            guard FluidAudioStager.isPlainRelativePath(path), !model.id.contains("/"), !model.id.hasPrefix(".") else { throw InstallViewError.unsafePath(path) }
            guard store.contains(sha) else { throw InstallViewError.missingBlob(path: path, sha256: sha) }
        }
        try fm.createDirectory(at: models.installs, withIntermediateDirectories: true)
        try fm.createDirectory(at: models.manifests, withIntermediateDirectories: true)
        let final = models.install(model.id)
        let tmp = models.staging.appending(path: "\(model.id).tmp", directoryHint: .isDirectory)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (path, sha) in manifest.files.sorted(by: { $0.key < $1.key }) {
            try manifest.placement.place(store.url(sha), at: tmp.appending(path: path))
        }
        let data = manifest.encoded()
        try data.write(to: tmp.appending(path: "manifest.json"), options: .atomic)
        FileManager.default.createFile(atPath: tmp.appending(path: ".verified").path, contents: nil)  // blobs verified at commit
        try data.write(to: models.manifest(manifest.sha256), options: .atomic)
        // Atomic swap: the old view (if any) and the new one trade names in one renamex_np(RENAME_SWAP) — a crash
        // leaves the old or the new view, never none (release review) — then the old one goes. A volume without
        // swap support falls back to move-aside (old → staging, new → name).
        if fm.fileExists(atPath: final.path), renamex_np(tmp.path, final.path, UInt32(RENAME_SWAP)) == 0 {
            try? fm.removeItem(at: tmp)
        } else if fm.fileExists(atPath: final.path) {
            let old = models.staging.appending(path: "\(model.id).old", directoryHint: .isDirectory)
            try? fm.removeItem(at: old)
            try fm.moveItem(at: final, to: old)
            try fm.moveItem(at: tmp, to: final)
            try? fm.removeItem(at: old)
        } else {
            try fm.moveItem(at: tmp, to: final)
        }
        if let database, let slot {
            try database.write { db in
                let prev = try ModelInstallRecord.fetchOne(db, key: slot)
                let keep = prev.map { $0.manifestSHA == manifest.sha256 ? $0.previousManifestSHA : $0.manifestSHA } ?? nil
                try ModelInstallRecord(slot: slot, catalogEntryID: model.id, manifestSHA: manifest.sha256, state: "ready",
                                       previousManifestSHA: keep, installedAt: Date()).save(db)
            }
        }
        return final
    }

    /// Re-creates every view from its manifest (rollback recipe: `models install --from-store`).
    public static func rematerialize(_ manifest: InstallManifest, models: ModelsDirectory) throws {
        let fm = FileManager.default
        let tmp = models.staging.appending(path: "\(manifest.modelID).tmp", directoryHint: .isDirectory)
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = BlobStore(models: models)
        for (path, sha) in manifest.files { try manifest.placement.place(store.url(sha), at: tmp.appending(path: path)) }
        try manifest.encoded().write(to: tmp.appending(path: "manifest.json"))
        FileManager.default.createFile(atPath: tmp.appending(path: ".verified").path, contents: nil)
        let final = models.install(manifest.modelID)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: tmp, to: final)
    }

    /// Removes a view (blobs stay until `GarbageCollector.sweep()`); `.tmp` leftovers of a killed install too.
    public static func remove(_ id: String, models: ModelsDirectory) throws {
        for u in [models.install(id), models.staging.appending(path: "\(id).tmp"), models.staging.appending(path: "\(id).old")] {
            if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) }
        }
    }

    /// Launch cleanup: half-written views from a crash (`staging/` is never loaded).
    public static func cleanLeftovers(models: ModelsDirectory) {
        try? FileManager.default.removeItem(at: models.staging)
    }
}
