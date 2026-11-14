// M8.T10 step 6 (R-205 AC2 "Clean up reviews before deleting"): what can go, with sizes, each a checkbox. `plan` only
// reads; `execute` deletes exactly the checked items' files and returns the bytes freed. Orphan blobs and partial
// downloads come from the M2 GarbageCollector's mark (the rollback window and open downloads are kept).
import AntiChatStorage
import Foundation
import GRDB

public struct CleanupItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case caches, oldLogs, oldMedia, oldBackups, orphanBlobs, partialDownloads }
    public var kind: Kind
    public var files: [URL]
    public var bytes: Int64
    public var defaultChecked: Bool
    public var id: String { kind.rawValue }
    /// `storage.cleanup.<kind>` (copy-deck §9).
    public var copyKey: String { "storage.cleanup.\(kind.rawValue)" }
}

public enum CleanupPlanner {
    /// - Parameters:
    ///   - modelLoaded: a model is resident now, so the Metal shader cache stays.
    ///   - mediaAge: media older than this and not referenced by a pinned chat is offered (default unchecked).
    ///   - active: blob digests an open download or install still needs (GarbageCollector `active`).
    public static func plan(_ paths: DataPaths, database: AppDatabase?, modelLoaded: Bool = false,
                            mediaAge: TimeInterval = 90 * 86_400, now: Date = Date(), active: Set<String> = [],
                            backupRetention: Int = 7) -> [CleanupItem] {
        let fm = FileManager.default
        var out: [CleanupItem] = []
        func item(_ k: CleanupItem.Kind, _ files: [URL], checked: Bool = true) {
            guard !files.isEmpty else { return }
            out.append(CleanupItem(kind: k, files: files, bytes: files.reduce(0) { $0 + SpaceAccountant.allocated($1) }, defaultChecked: checked))
        }
        // Caches: every top-level entry of Caches/AntiChat (the Metal shader cache stays while a model is loaded).
        let caches = ((try? fm.contentsOfDirectory(at: paths.caches, includingPropertiesForKeys: nil)) ?? [])
            .filter { !(modelLoaded && $0.lastPathComponent.lowercased().contains("metal")) }
        item(.caches, caches.sorted { $0.path < $1.path })
        // Old logs: rotated files (`*.log.<n>`, `*.1.log`, `*.gz`) under Logs/AntiChat*.
        let logs = walk(paths.logs).filter { u in
            let n = u.lastPathComponent
            return n.range(of: #"\.log\.\d+$|\.\d+\.log$|\.gz$"#, options: .regularExpression) != nil
        }
        item(.oldLogs, logs)
        // Media older than 90 days and not referenced by a pinned chat.
        let pinned = Set((try? database?.read { db in
            try String.fetchAll(db, sql: """
                SELECT b.path FROM file_blob b JOIN attachment a ON a.blob_id = b.id JOIN message m ON m.id = a.message_id
                JOIN chat c ON c.id = m.chat_id WHERE c.pinned = 1
                UNION SELECT b.path FROM file_blob b JOIN project_file f ON f.blob_id = b.id
                """)
        }) ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let cutoff = now.addingTimeInterval(-mediaAge)
        let oldMedia = walk(paths.container.appendingPathComponent("Media")).filter { u in
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            return m < cutoff && !pinned.contains(u.standardizedFileURL.path)
        }
        item(.oldMedia, oldMedia, checked: false)
        // Backups beyond retention (daily-*: keep the newest `backupRetention`; pre-* and pre-restore-* are BackupService's).
        let backups = ((try? fm.contentsOfDirectory(at: paths.container.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("daily-") }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        item(.oldBackups, Array(backups.dropFirst(backupRetention)))
        // Orphan blobs and partial downloads: the M2 GarbageCollector's mark (current + previous manifests, open jobs).
        let models = ModelsDirectory(root: paths.models)
        if let marked = try? GarbageCollector(models: models, database: database).marked(active: active) {
            let blobs = BlobStore(models: models).all().filter { !marked.blobs.contains($0) }.map { BlobStore(models: models).url($0) }
            item(.orphanBlobs, blobs)
            let parts = ((try? fm.contentsOfDirectory(at: models.partial, includingPropertiesForKeys: nil)) ?? []).filter { u in
                let sha = u.deletingPathExtension().lastPathComponent
                return !active.contains(sha)
            }
            item(.partialDownloads, parts.sorted { $0.path < $1.path })
        }
        return out
    }

    /// `execute` for model files, re-marked at delete time (release review): the review sheet can stay open while a
    /// download commits or an install view is written, so an orphan blob a view, slot or open job now names (and a
    /// partial download now in `active`) is kept. A failed mark keeps every model file.
    @discardableResult
    public static func execute(_ items: [CleanupItem], checked: Set<CleanupItem.Kind>, paths: DataPaths,
                               database: AppDatabase?, active: Set<String> = []) -> Int64 {
        let models = ModelsDirectory(root: paths.models)
        guard let mark = try? GarbageCollector(models: models, database: database).marked(active: active) else {
            return execute(items, checked: checked.subtracting([.orphanBlobs, .partialDownloads]))
        }
        let safe = items.map { item -> CleanupItem in
            var i = item
            switch i.kind {
            case .orphanBlobs: i.files = i.files.filter { !mark.blobs.contains($0.lastPathComponent) }
            case .partialDownloads: i.files = i.files.filter { !active.contains($0.deletingPathExtension().lastPathComponent) }
            default: break
            }
            return i
        }
        return execute(safe, checked: checked)
    }

    /// Deletes the files of the checked items only; returns the bytes freed (measured before deletion).
    @discardableResult
    public static func execute(_ items: [CleanupItem], checked: Set<CleanupItem.Kind>) -> Int64 {
        var freed: Int64 = 0
        for i in items where checked.contains(i.kind) {
            for f in i.files {
                let b = SpaceAccountant.allocated(f)
                if (try? FileManager.default.removeItem(at: f)) != nil { freed += b }
            }
        }
        return freed
    }

    static func walk(_ root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return e.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
    }
}
