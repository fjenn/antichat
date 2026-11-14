// M2.T11 steps 4–5 (R-294 AC2–AC3; P-platform-04 rollback window): switching a slot to the updated model and back.
//   flip:    the new install view is materialised (atomic rename), then in ONE transaction the slot's row gets
//            manifest_sha = new, previous_manifest_sha = old, state = "trial". The old view stays on disk.
//   confirm: the first successful load ends the trial (state "ready") and drops the old view; its manifest stays named
//            by previous_manifest_sha, so `antichat-cli models rollback --slot` can still restore it (GC keeps it).
//   revert:  the first failed load flips back (old view rebuilt from its manifest, row manifest = old, previous =
//            nil, state "ready") and only then garbage-collects the failed model (never before: by design the old
//            install must be intact first).
import AntiChatStorage
import Foundation
import GRDB

public enum SlotFlip {
    public static let trialState = "trial"

    public enum FlipError: Error, Equatable { case noSlot(String), noPreviousManifest(String) }

    /// Flips `slot` to `model` (all its blobs must already be in the store). False = the slot already holds it.
    @discardableResult
    public static func flip(slot: String, to model: CatalogModel, catalogVersion: Int, models: ModelsDirectory, database: AppDatabase) throws -> Bool {
        guard let old = try database.read({ try ModelInstallRecord.fetchOne($0, key: slot) }) else { throw FlipError.noSlot(slot) }
        // Already on this model (a second flip of the same update): keep the row, or previous would name the new
        // model itself and the real rollback target would be collected (M2 review #3).
        if old.catalogEntryID == model.id { return false }
        try InstallView.materialize(model, catalogVersion: catalogVersion, models: models)
        let manifest = InstallManifest(model: model, catalogVersion: catalogVersion)
        try database.write { db in
            try ModelInstallRecord(slot: slot, catalogEntryID: model.id, manifestSHA: manifest.sha256, state: trialState,
                                   previousManifestSHA: old.manifestSHA, installedAt: Date()).save(db)
        }
        return true
    }

    /// The first load of the new model worked: the trial ends and the old view goes (its blobs stay in the rollback
    /// window through previous_manifest_sha).
    public static func confirm(slot: String, models: ModelsDirectory, database: AppDatabase) throws {
        guard var row = try database.read({ try ModelInstallRecord.fetchOne($0, key: slot) }), row.state == trialState else { return }
        row.state = "ready"
        try database.write { try row.save($0) }
        if let prev = row.previousManifestSHA, let m = InstallManifest.load(models.manifest(prev)), m.modelID != row.catalogEntryID,
           !(try isReferenced(m.modelID, except: slot, database: database)) {
            try InstallView.remove(m.modelID, models: models)
        }
    }

    /// The first load failed: back to the previous install, then the failed model's view and unshared blobs go.
    /// Returns the failed model id.
    @discardableResult
    public static func revert(slot: String, models: ModelsDirectory, database: AppDatabase, active: Set<String> = []) throws -> String {
        guard let row = try database.read({ try ModelInstallRecord.fetchOne($0, key: slot) }) else { throw FlipError.noSlot(slot) }
        guard let prev = row.previousManifestSHA, let m = InstallManifest.load(models.manifest(prev)) else { throw FlipError.noPreviousManifest(slot) }
        if !FileManager.default.fileExists(atPath: models.install(m.modelID).appending(path: "manifest.json").path) {
            try InstallView.rematerialize(m, models: models)
        }
        try database.write { db in
            try ModelInstallRecord(slot: slot, catalogEntryID: m.modelID, manifestSHA: prev, state: "ready", previousManifestSHA: nil,
                                   installedAt: Date()).save(db)
        }
        if row.catalogEntryID != m.modelID, !(try isReferenced(row.catalogEntryID, except: slot, database: database)) {
            try InstallView.remove(row.catalogEntryID, models: models)
        }
        try GarbageCollector(models: models, database: database).sweep(active: active)
        return row.catalogEntryID
    }

    static func isReferenced(_ id: String, except slot: String, database: AppDatabase) throws -> Bool {
        try database.read { try ModelInstallRecord.filter(Column("catalog_entry_id") == id && Column("slot") != slot).fetchCount($0) > 0 }
    }
}
