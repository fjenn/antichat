// M2 review #1/#2/#10 (R-293, R-294 rollback window, P-platform-04): the one way the app deletes models.
// Settings › Capabilities "Remove models", the starter removal under Advanced and Settings › Evil Mode "Remove Evil
// models" all run
//   1. evict: the ids leave the helper's ModelScheduler before their files go (a loaded model keeps its pages);
//   2. delete: their install views and the `model_install` slots that hold them;
//   3. collect: GarbageCollector with the real database (current + previous manifests, the rollback window) and the
//      full retained set — every open download job, every verified file whose model has no install view yet, the
//      setup install's tracked models and the update service's downloading / waiting-to-flip models.
// It is async and does file work only on the caller's executor; the UI calls it from a detached task (never main).
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB

public enum ModelRemoval {
    /// `releasing` = model ids whose files may go even though a download job or the setup still names them (the
    /// removed ids are always included).
    public typealias Retained = @Sendable (_ releasing: Set<String>) async -> Set<String>

    @discardableResult
    public static func remove(_ ids: Set<String>, releasing: Set<String> = [], models: ModelsDirectory, database: AppDatabase?,
                              evict: @Sendable (Set<String>) async -> Void, retained: Retained) async -> GarbageCollector.Report? {
        guard !ids.isEmpty || !releasing.isEmpty else { return nil }
        if !ids.isEmpty { await evict(ids) }
        for id in ids {
            do { try InstallView.remove(id, models: models) } catch { AppLog.log(.store, .error, "remove \(id): \(error)") }
        }
        if let database, !ids.isEmpty {
            do {
                _ = try database.write { db in
                    try ModelInstallRecord.filter(ids.contains(Column("catalog_entry_id"))).deleteAll(db)
                }
            } catch { AppLog.log(.store, .error, "remove slots: \(error)") }
        }
        let keep = await retained(releasing.union(ids))
        do {
            return try GarbageCollector(models: models, database: database).sweep(active: keep)
        } catch {
            AppLog.log(.store, .error, "remove models GC: \(error)")
            return nil
        }
    }

    /// The live retained set over the app's queue, setup install and update service (any may be nil).
    public static func retained(coordinator: DownloadCoordinator?, setup: SetupInstaller?, updates: ModelUpdateService?,
                                releasing: Set<String>) async -> Set<String> {
        var out = await coordinator?.retainedSHA256s(releasing: releasing) ?? []
        if let setup { out.formUnion(await setup.retainedSHA256s(releasing: releasing)) }
        if let updates { out.formUnion(await updates.heldSHA256s) }
        return out
    }
}
