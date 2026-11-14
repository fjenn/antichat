// M8.T04 (R-064): the window's projects — sidebar ProjectRows and the Projects list follow a ValueObservation of
// `project` (+ chat counts); a project page has its own model (chats, files with their real progress, instructions
// autosaved after 500 ms, project-only memory). Linked folders are watched app-wide (ProjectFolderWatchers).
import AntiChatDesign
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import GRDB

@MainActor @Observable
public final class ProjectsModel {
    public let database: AppDatabase
    public private(set) var projects: [ProjectSummary] = []
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    var store: ProjectStore { ProjectStore(database: database) }
    private static var byDatabase: [ObjectIdentifier: ProjectsModel] = [:]

    /// One model per database (every window shares it; watchers start once).
    public static func shared(database: AppDatabase) -> ProjectsModel {
        if let m = byDatabase[ObjectIdentifier(database)] { return m }
        let m = ProjectsModel(database: database)
        byDatabase[ObjectIdentifier(database)] = m
        return m
    }

    /// The app's project file indexer: chunks get vectors through the database's document embedder.
    nonisolated public static func indexer(_ database: AppDatabase) -> ProjectFileIndexer {
        ProjectFileIndexer(database: database, embedder: DocumentEmbedding.for(database).embedder)
    }

    public init(database: AppDatabase) {
        self.database = database
        guard FeatureFlag.projects.isEnabled() else { return }
        // Constant region (one SQL, no key filter): refetched on a reader, never inside the writer (AT-NFR-S3).
        cancellable = ValueObservation.trackingConstantRegion { try ProjectStore.summaries($0) }
            .removeDuplicates()
            .start(in: database.reader, scheduling: .mainActor, onError: { _ in }, onChange: { [weak self] in self?.projects = $0 })
        ProjectFolderWatchers.shared.start(database: database)
    }

    @discardableResult
    func create(name: String, icon: String) -> Project? {
        do { return try store.create(name: name, icon: icon) } catch {
            AppLog.log(.ui, .error, "project create failed: \(error)")
            return nil
        }
    }

    func move(chatID: String, to projectID: String?) {
        do { try store.move(chatID: chatID, to: projectID) } catch { AppLog.log(.ui, .error, "move chat failed: \(error)") }
    }

    func delete(_ id: String, keepChats: Bool) {
        ProjectFolderWatchers.shared.stop(projectID: id)
        do { try store.delete(id, keepChats: keepChats) } catch { AppLog.log(.ui, .error, "project delete failed: \(error)") }
    }
}

/// One FSEvents watcher per project with a linked folder (started at launch and when a folder is linked).
@MainActor
final class ProjectFolderWatchers {
    static let shared = ProjectFolderWatchers()
    private var watchers: [String: LinkedFolderWatcher] = [:]
    private var started = false

    func start(database: AppDatabase) {
        guard !started, !database.isInMemory else { return }
        started = true
        let rows = (try? database.read { try Row.fetchAll($0, sql: "SELECT id, linked_folder_path FROM project WHERE linked_folder_path IS NOT NULL") }) ?? []
        for r in rows { watch(projectID: r["id"], path: r["linked_folder_path"], database: database) }
        reindexPending(database: database)
    }

    /// Copied project files not indexed yet (an AntiChat import, a quit mid-index): index them again (review fix).
    func reindexPending(database: AppDatabase) {
        guard !database.isInMemory else { return }
        Task.detached(priority: .utility) { _ = await ProjectsModel.indexer(database).reindexPending() }
    }

    func watch(projectID: String, path: String, database: AppDatabase, catchUp: Bool = true) {
        watchers[projectID]?.stop()
        // The indexer is made per rescan, so an embed model attached after launch is used (DocumentEmbedding).
        watchers[projectID] = LinkedFolderWatcher(folder: URL(fileURLWithPath: path, isDirectory: true)) {
            await ProjectFolderWatchers.shared.rescan(projectID, database: database).value
        }
        if catchUp { rescan(projectID, database: database) }  // changes made while closed
    }

    /// One rescan at a time per project (review fix: the launch catch-up and a watcher event could overlap and hit
    /// the linked-file unique index, which silently ended the rest of a rescan).
    private var rescans: [String: Task<Void, Never>] = [:]

    @discardableResult
    func rescan(_ projectID: String, database: AppDatabase) -> Task<Void, Never> {
        let previous = rescans[projectID]
        let t = Task.detached(priority: .utility) {
            await previous?.value
            _ = try? await ProjectsModel.indexer(database).rescan(projectID)
        }
        rescans[projectID] = t
        return t
    }

    func stop(projectID: String) {
        watchers.removeValue(forKey: projectID)?.stop()
    }

    /// Remove everything: every watcher stops (no rescan writes into a deleted container).
    func stopAll() {
        for w in watchers.values { w.stop() }
        watchers = [:]
    }
}

@MainActor @Observable
final class ProjectPageModel {
    struct ChatRowItem: Identifiable, Equatable {
        var id: String
        var title: String
        var updatedAt: Date
    }

    let projectID: String
    let database: AppDatabase
    private(set) var project: Project?
    private(set) var chats: [ChatRowItem] = []
    private(set) var files: [ProjectFile] = []
    var instructions = ""
    /// Shown after an add that passed the limit (`project.files.limit`).
    var limitHit = false
    private(set) var folderMissing = false
    @ObservationIgnored private var cancellable: AnyDatabaseCancellable?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    var store: ProjectStore { ProjectStore(database: database) }

    struct Snapshot: Equatable {
        var project: Project?
        var chats: [ChatRowItem]
        var files: [ProjectFile]
    }

    init(projectID: String, database: AppDatabase) {
        self.projectID = projectID
        self.database = database
        instructions = (try? store.instructions(projectID)) ?? ""
        // The tables it reads, whole (a constant region): refetched on a reader, never inside the writer.
        cancellable = ValueObservation.tracking(regions: [Table("project"), Table("chat"), Table("project_file")]) { db in
            Snapshot(
                project: try Project.fetchOne(db, key: projectID),
                chats: try Row.fetchAll(db, sql: """
                    SELECT id, title, updated_at FROM chat WHERE project_id = ? AND archived_at IS NULL ORDER BY updated_at DESC
                    """, arguments: [projectID]).map { ChatRowItem(id: $0["id"], title: $0["title"], updatedAt: Date(timeIntervalSince1970: $0["updated_at"])) },
                files: try ProjectFile.filter(Column("project_id") == projectID).order(Column("origin"), Column("display_name")).fetchAll(db))
        }
        .removeDuplicates()
        .start(in: database.reader, scheduling: .mainActor, onError: { _ in }, onChange: { [weak self] s in
            self?.project = s.project
            self?.chats = s.chats
            self?.files = s.files
            self?.checkFolder()
        })
    }

    private func checkFolder() {
        guard let path = project?.linkedFolderPath else { folderMissing = false; return }
        var isDir: ObjCBool = false
        folderMissing = !(FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue)
    }

    /// Step 3: autosave 500 ms after the last keystroke.
    func instructionsChanged() {
        saveTask?.cancel()
        let text = instructions, id = projectID, store = store
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? store.setInstructions(id, text)
        }
    }

    func flushInstructions() {
        saveTask?.cancel()
        try? store.setInstructions(projectID, instructions)
    }

    var projectOnlyMemory: Bool {
        get { project?.memoryMode == .project }
        set { try? store.setMemoryMode(projectID, newValue ? .project : .global) }
    }

    func rename(_ name: String) { try? store.rename(projectID, to: name) }
    func setIcon(_ icon: String) { try? store.setIcon(projectID, icon) }

    func add(_ urls: [URL]) {
        let id = projectID, db = database
        let room = (try? store.admit(id, sizes: urls.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) })) ?? 0
        limitHit = room < urls.count
        Task.detached(priority: .userInitiated) { _ = try? await ProjectsModel.indexer(db).add(urls, to: id) }
    }

    func link(_ folder: URL) {
        let id = projectID, db = database
        Task.detached(priority: .userInitiated) {
            _ = try? await ProjectsModel.indexer(db).link(folder, to: id)
            await MainActor.run { ProjectFolderWatchers.shared.watch(projectID: id, path: folder.path, database: db, catchUp: false) }
        }
    }

    func remove(_ fileID: String) { try? store.removeFile(fileID) }
}
