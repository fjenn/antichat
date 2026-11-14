// M8.T06 steps 3, 8 (R-092): the import entry point the UI drives. Detects the file (ChatGPT / Claude / AntiChat /
// unsupported), runs ChatImporter off the main thread with progress, and cancels between conversations (≤ 1 s:
// one conversation's parse + write). The parser and tree mapping are ports of osaurus@2922745
// ChatSessionImporter (P-platform-10, A-M0-06) in AntiChatStorage; this type only coordinates. No network.
import AntiChatFoundation
import AntiChatStorage
import Foundation

public final class ImportCoordinator: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case progress(ImportProgress)
        case finished(ImportSummary)
        case failed(String)
        /// AT-092: after `finished`, the deferred full-text pass (0…1); the imported chats are usable throughout and
        /// search finds them as the pass reaches them.
        case searchIndex(Double)
    }

    public let database: AppDatabase
    public let mediaRoot: URL
    private let lock = NSLock()
    private var cancelled = false

    public init(database: AppDatabase, mediaRoot: URL = AppDatabase.containerURL().appendingPathComponent("Media", isDirectory: true)) {
        self.database = database
        self.mediaRoot = mediaRoot
    }

    public static func detect(_ url: URL) -> ImportDetection { ChatImporter.detect(url) }

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Runs the import of `url` on a utility thread; events arrive in order, `finished` / `failed` last.
    public func start(_ url: URL) -> AsyncStream<Event> {
        lock.lock(); cancelled = false; lock.unlock()
        // Unbounded (review fix): `.finished` / `.failed` must never be dropped behind progress events.
        let (stream, sink) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let importer = ChatImporter(database: database, mediaRoot: mediaRoot)
        Thread.detachNewThread { [self] in
            Thread.current.qualityOfService = .utility
            switch Self.detect(url) {
            case .chatGPT, .claude:
                do {
                    var last = Date.distantPast
                    let summary = try importer.run(url, progress: { p in
                        let now = Date()
                        if now.timeIntervalSince(last) > 0.05 || p.fraction >= 1 { last = now; sink.yield(.progress(p)) }
                    }, isCancelled: { self.isCancelled })
                    sink.yield(.finished(summary))
                } catch {
                    sink.yield(.failed("import.failed"))
                }
                Self.indexSearch(database, sink: sink)
            case .antichat:  // M8.T07 step 3: an AntiChat export-all zip (same ids, dedup by chat id)
                do {
                    var last = Date.distantPast
                    let summary = try AntiChatImporter(database: database, mediaRoot: mediaRoot).run(url, progress: { p in
                        let now = Date()
                        if now.timeIntervalSince(last) > 0.05 || p.fraction >= 1 { last = now; sink.yield(.progress(p)) }
                    }, isCancelled: { self.isCancelled })
                    sink.yield(.finished(summary))
                } catch ImportError.newerExport {
                    sink.yield(.failed("import.newerExport"))
                } catch {
                    sink.yield(.failed("import.failed"))
                }
                Self.indexSearch(database, sink: sink)
            case .unsupported:
                sink.yield(.failed("import.unsupported"))
            }
            sink.finish()
        }
        return stream
    }

    /// The deferred full-text pass of the import (also after a failed or cancelled one: its chats are kept).
    static func indexSearch(_ database: AppDatabase, sink: AsyncStream<Event>.Continuation) {
        guard !database.isInMemory else { return }
        let backlog = MessageSearchBacklog(database: database)
        guard let first = try? backlog.status(), !first.isDone else { return }
        var last = Date.distantPast
        sink.yield(.searchIndex(first.fraction))
        do {
            try backlog.run(progress: { st in
                let now = Date()
                if now.timeIntervalSince(last) > 0.1 || st.isDone { last = now; sink.yield(.searchIndex(st.fraction)) }
            })
        } catch {
            AppLog.log(.store, .error, "import search index: \(error)")  // resumed at the next launch
        }
        sink.yield(.searchIndex(1))
    }
}
