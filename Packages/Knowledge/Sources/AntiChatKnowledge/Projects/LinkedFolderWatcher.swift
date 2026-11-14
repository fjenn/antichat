// M8.T04 step 5: a linked folder is watched with an FSEventStream (latency 2 s, file-level events, `.git` /
// `node_modules` / `DerivedData` events ignored); any change triggers ProjectFileIndexer.rescan, which re-indexes by
// mtime + size and drops deleted files. Rescans never overlap (one in flight, one queued).
import CoreServices
import Foundation
import Synchronization

public final class LinkedFolderWatcher: @unchecked Sendable {
    public let folder: URL
    private let onChange: @Sendable () async -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "antichat.project.fsevents", qos: .utility)
    private let state = Mutex<(running: Bool, again: Bool)>((false, false))

    public init(folder: URL, latency: TimeInterval = 2, onChange: @escaping @Sendable () async -> Void) {
        self.folder = folder
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil,
                                           release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<LinkedFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let relevant = list.prefix(count).contains { p in
                !p.split(separator: "/").contains { ProjectFileIndexer.skippedFolders.contains(String($0)) }
            }
            if relevant { me.fire() }
        }
        stream = FSEventStreamCreate(nil, callback, &context, [folder.path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                                              | kFSEventStreamCreateFlagNoDefer))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    private func fire() {
        let start = state.withLock { s -> Bool in
            if s.running { s.again = true; return false }
            s.running = true
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) { [self] in
            while true {
                await onChange()
                let more = state.withLock { s -> Bool in
                    if s.again { s.again = false; return true }
                    s.running = false
                    return false
                }
                if !more { return }
            }
        }
    }

    /// Review fix (M8.T16): the stream is torn down on its own callback queue, so no callback can be running with
    /// the unretained `self` while (or after) it goes.
    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
