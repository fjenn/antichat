// M8.T04 step 5 (R-064 AC2): project files indexed locally, no network. Copied files go through the M6 store
// (AttachmentIntake.copyIntoStore: `<container>/Media/<yyyy>/<sha256>.<ext>`, dedup by sha256, `file_blob` reused) and
// ExtractionService; a linked folder's files are read in place (`origin = 'linked'`, no copy, no limit; soft cap
// 10,000 files; hidden files, packages, `.git` / `node_modules` / `DerivedData` and files > 200 MB skipped). Text is
// cut with the M6 document chunker (unit-aligned, page_ref = PDF page / slide / sheet / section) into
// `chunk(source='project_file', source_id=project_file.id)` (+ fts by trigger; vectors when an embedder is attached).
// `project_file.progress` is the real fraction (copy 0–0.3, extraction 0.3–0.9, chunks 0.9–1).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import GRDB

public actor ProjectFileIndexer {
    public static let maxLinkedFileBytes: Int64 = 200 * 1024 * 1024
    public static let linkedSoftCap = 10_000
    public static let skippedFolders: Set<String> = [".git", "node_modules", "DerivedData", ".build", "Pods"]

    public let database: AppDatabase
    public let mediaRoot: URL
    public let embedder: (any Embedder)?
    private let extraction = ExtractionService()
    private var store: ProjectStore { ProjectStore(database: database) }

    /// `embedder` has no default on purpose: the app passes `DocumentEmbedding.for(database).embedder` (a nil default let
    /// the app build every indexer without vectors while the benches passed one).
    public init(database: AppDatabase, mediaRoot: URL = AttachmentIntake.defaultMediaRoot(), embedder: (any Embedder)?) {
        self.database = database
        self.mediaRoot = mediaRoot
        self.embedder = embedder
    }

    public struct AddResult: Sendable, Equatable {
        public var added: [String]
        /// Files beyond the 100-file / 2 GB limit (nothing of them was copied): `project.files.limit`.
        public var rejected: Int
    }

    /// Adds files to a project: the limit check comes first, then each admitted file is copied and indexed.
    public func add(_ urls: [URL], to projectID: String) async throws -> AddResult {
        let sizes = urls.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        // Admit and insert in one write transaction (review fix): concurrent adds cannot overshoot 100 files / 2 GB.
        let rows = try database.write { db -> [(ProjectFile, URL)] in
            let room = try ProjectStore.admit(db, projectID, sizes: sizes)
            return try zip(urls.prefix(room), sizes).map { url, size in
                let f = ProjectFile(id: StorageID.make(), projectID: projectID, displayName: url.lastPathComponent, size: size,
                                    origin: .copied, indexState: .pending, progress: 0, createdAt: Date())
                try f.insert(db)
                return (f, url)
            }
        }
        for (f, url) in rows { await index(fileID: f.id, source: url) }
        return AddResult(added: rows.map(\.0.id), rejected: urls.count - rows.count)
    }

    /// Indexes one project file from `source` (copied: into the media store first). Errors end in `index_state = error`.
    func index(fileID: String, source: URL) async {
        guard var f = try? database.read({ try ProjectFile.fetchOne($0, key: fileID) }) else { return }
        do {
            let sniff = try TypeSniffer.sniff(source)
            guard sniff.kind.isSupported else { throw ExtractionError.unsupported(ext: sniff.ext) }
            f.uti = sniff.uttype.identifier
            try update(&f) { $0.indexState = .indexing; $0.progress = 0.05 }
            var readURL = source
            if f.origin == .copied {
                let intake = AttachmentIntake(database: database, mediaRoot: mediaRoot, incognito: false)
                let (sha, stored) = try await intake.copyIntoStore(source, kind: sniff.kind)
                let size = Int64((try? stored.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int(f.size))
                let blobID = try database.write { db -> String in
                    if let b = try FileBlobRecord.filter(Column("sha256") == sha).fetchOne(db) { return b.id }
                    let b = FileBlobRecord(sha256: sha, size: size, path: stored.path, origin: .upload)
                    try b.insert(db)
                    return b.id
                }
                readURL = stored
                try update(&f) { $0.blobID = blobID; $0.size = size; $0.progress = 0.3 }
            }
            let fileID = f.id
            let db = database
            let doc = try await extraction.extract(url: readURL, kind: sniff.kind) { p in
                try? db.write { try $0.execute(sql: "UPDATE project_file SET progress = ? WHERE id = ?",
                                               arguments: [0.3 + 0.6 * p.fraction, fileID]) }
            }
            try database.write { db in
                try ProjectStore.deleteChunks(db, fileIDs: [fileID])
                let units = doc.units.isEmpty
                    ? [ExtractedDocument.Unit(kind: .section, index: 1, start: 0, end: doc.markdown.utf16.count)] : doc.units
                var ord = 0
                for u in units {
                    for piece in DocumentIndexer.pieces(doc.text(of: u)) {
                        try db.execute(sql: """
                            INSERT INTO chunk(source, source_id, chat_id, ord, text, created_at, page_ref) VALUES (?, ?, NULL, ?, ?, ?, ?)
                            """, arguments: [ProjectFile.chunkSource, fileID, ord, piece, Date().timeIntervalSince1970,
                                             DocumentIndexer.pageRef(u)])
                        ord += 1
                    }
                }
            }
            try saveText(Self.markedText(doc), fileID: fileID)
            try update(&f) {
                $0.textTokens = doc.tokenCount ?? max(1, doc.charCount / 4)
                $0.pages = doc.pageCount ?? doc.slideCount
                $0.indexState = .ready
                $0.progress = 1
                $0.errorCode = nil
            }
            await embed(fileID: fileID)
        } catch {
            try? update(&f) { $0.indexState = .error; $0.errorCode = Self.code(error) }
        }
    }

    /// Review fix (M8.T16): copied files left `pending` or `indexing` (an AntiChat import, a quit mid-index) are
    /// indexed again from their stored blob. Returns how many were started.
    @discardableResult
    public func reindexPending(projectID: String? = nil) async -> Int {
        let rows = (try? database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id, b.path FROM project_file f JOIN file_blob b ON b.id = f.blob_id
                WHERE f.origin = 'copied' AND f.index_state IN ('pending', 'indexing') AND (? IS NULL OR f.project_id = ?)
                """, arguments: [projectID, projectID])
        }) ?? []
        var n = 0
        for r in rows {
            guard let id: String = r["id"], let path: String = r["path"], FileManager.default.fileExists(atPath: path) else { continue }
            await index(fileID: id, source: URL(fileURLWithPath: path))
            n += 1
        }
        return n
    }

    static func code(_ error: any Error) -> String {
        if case ExtractionError.unsupported = error { return "files.unsupported" }
        return "files.readFailed"
    }

    private func update(_ f: inout ProjectFile, _ change: (inout ProjectFile) -> Void) throws {
        change(&f)
        let row = f
        try database.write { try row.update($0) }
    }

    /// M8.T05 step 1: the whole-file text keeps intake's pages as `[p.{k}]` markers (paged formats only).
    public static func markedText(_ doc: ExtractedDocument) -> String {
        guard doc.units.contains(where: { $0.kind == .page }) else { return doc.markdown }
        return doc.units.map { u in u.kind == .page ? "[p.\(u.index)]\n" + doc.text(of: u) : doc.text(of: u) }
            .joined(separator: "\n")
    }

    /// The extracted text (whole-file context, M8.T05): `<mediaRoot>/projects/<file id>.md`.
    public nonisolated func textURL(fileID: String) -> URL {
        mediaRoot.appendingPathComponent("projects", isDirectory: true).appendingPathComponent("\(fileID).md")
    }

    public nonisolated func text(fileID: String) -> String? { try? String(contentsOf: textURL(fileID: fileID), encoding: .utf8) }

    private func saveText(_ md: String, fileID: String) throws {
        let url = textURL(fileID: fileID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(md.utf8).write(to: url, options: .atomic)
    }

    private func embed(fileID: String) async {
        guard let embedder, !database.isInMemory else { return }
        while true {
            guard let rows = try? database.read({ db in
                try Row.fetchAll(db, sql: """
                    SELECT c.id, c.text FROM chunk c WHERE c.source = ? AND c.source_id = ?
                      AND NOT EXISTS (SELECT 1 FROM chunk_vec v WHERE v.rowid = c.id) ORDER BY c.ord LIMIT 32
                    """, arguments: [ProjectFile.chunkSource, fileID])
            }), !rows.isEmpty,
                let vectors = try? await embedder.embed(rows.map { $0["text"] }, kind: .document), vectors.count == rows.count
            else { return }
            try? database.write { db in
                for (r, v) in zip(rows, vectors) where v.count == VecLoader.dimensions {
                    try db.execute(sql: "INSERT OR REPLACE INTO chunk_vec(rowid, embedding) VALUES (?, ?)",
                                   arguments: [r["id"] as Int64, ChunkTables.blob(v)])
                }
            }
        }
    }

    // MARK: Linked folder

    /// Links `folder` (a minimal bookmark + its path; the app is not sandboxed) and indexes it.
    @discardableResult
    public func link(_ folder: URL, to projectID: String) async throws -> ScanResult {
        let bookmark = try? folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try database.write { db in
            try db.execute(sql: "UPDATE project SET linked_folder_bookmark = ?, linked_folder_path = ?, updated_at = ? WHERE id = ?",
                           arguments: [bookmark, folder.path, Date().timeIntervalSince1970, projectID])
        }
        return try await rescan(projectID)
    }

    public struct ScanResult: Sendable, Equatable {
        public var indexed = 0
        public var removed = 0
        public var unchanged = 0
        /// More than 10,000 files: the rest were not indexed (notice).
        public var capped = false
        /// The folder is gone (`project.folder.missing`); the last index stays.
        public var missing = false
    }

    /// Re-reads the linked folder: new or changed files (mtime + size) are indexed, vanished ones lose their chunks.
    public func rescan(_ projectID: String) async throws -> ScanResult {
        var result = ScanResult()
        guard let path = try database.read({ try String.fetchOne($0, sql: "SELECT linked_folder_path FROM project WHERE id = ?", arguments: [projectID]) })
        else { return result }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            result.missing = true
            return result
        }
        let (found, capped) = Self.enumerate(root)
        result.capped = capped
        let existing = try database.read { db in
            try ProjectFile.filter(Column("project_id") == projectID && Column("origin") == "linked").fetchAll(db)
        }
        var byPath = Dictionary(existing.compactMap { f in f.relPath.map { ($0, f) } }, uniquingKeysWith: { a, _ in a })
        for item in found {
            if var f = byPath.removeValue(forKey: item.rel) {
                if f.mtime == item.mtime, f.size == item.size, f.indexState == .ready { result.unchanged += 1; continue }
                f.mtime = item.mtime
                f.size = item.size
                f.indexState = .pending
                f.progress = 0
                let row = f
                try database.write { try row.update($0) }
                await index(fileID: f.id, source: item.url)
            } else {
                let f = ProjectFile(id: StorageID.make(), projectID: projectID, displayName: item.url.lastPathComponent,
                                    size: item.size, relPath: item.rel, origin: .linked, indexState: .pending, progress: 0,
                                    mtime: item.mtime, createdAt: Date())
                try database.write { try f.insert($0) }
                await index(fileID: f.id, source: item.url)
            }
            result.indexed += 1
        }
        let gone = Array(byPath.values)
        if !gone.isEmpty {
            try database.write { db in
                try ProjectStore.deleteChunks(db, fileIDs: gone.map(\.id))
                for f in gone { try f.delete(db) }
            }
            for f in gone { try? FileManager.default.removeItem(at: textURL(fileID: f.id)) }
            result.removed = gone.count
        }
        return result
    }

    struct Found { var url: URL; var rel: String; var size: Int64; var mtime: Double }

    static func enumerate(_ root: URL) -> ([Found], Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], false) }
        var out: [Found] = []
        let base = root.standardizedFileURL.path
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) || v.isPackage == true { e.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, let size = v.fileSize, Int64(size) <= maxLinkedFileBytes,
                  let sniff = try? TypeSniffer.sniff(url), sniff.kind.isSupported else { continue }
            if out.count >= linkedSoftCap { return (out, true) }
            let path = url.standardizedFileURL.path
            let rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
            out.append(Found(url: url, rel: rel, size: Int64(size), mtime: v.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        return (out, false)
    }
}
