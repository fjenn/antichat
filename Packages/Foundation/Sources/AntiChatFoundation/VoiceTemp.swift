// M3 review P2-6: the voice temp audio (`$TMPDIR/AntiChat-dictation`: a dictation's recording until Recent recordings
// files it; `$TMPDIR/AntiChat-transcribe`: an audio attachment decoded to 16 kHz for transcription) lives in a
// per-process directory `<area>/<pid>/` claimed like the incognito temp dirs (`IncognitoTemp`: `.owner` = the pid).
// The normal paths delete each file when done; after a crash or a kill, the next launch of the app (dictation) or of
// the helper (transcription) removes what a dead process left — never a live process's files (a second app instance,
// a test host, another checkout's run share the user's $TMPDIR). Loose files of the older flat layout are removed once
// they are an hour old.
import Foundation

public enum VoiceTemp {
    public static let dictation = "AntiChat-dictation"
    public static let transcribe = "AntiChat-transcribe"
    static let looseFileAge: TimeInterval = 3_600

    /// `<root>/<area>/<pid>/`, created (0700) and owned by this process. fix/review P7: liveness is the owner's pid
    /// and start time (`IncognitoTemp.isLive`), so a dead process's directory is swept even when its pid now runs
    /// something else. A directory already here under this pid was left by a dead process that had the same pid (no
    /// live process can share it): its files go before this process claims it.
    public static func directory(_ area: String, root: URL = IncognitoTemp.defaultRoot) -> URL {
        let dir = root.appendingPathComponent(area, isDirectory: true)
            .appendingPathComponent("\(getpid())", isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path), !IncognitoTemp.isOwnedByThisProcess(dir) {
            try? FileManager.default.removeItem(at: dir)
        }
        IncognitoTemp.claim(dir)
        return dir
    }

    /// Removes the per-process directories of processes that are gone and stale loose files; returns what it removed.
    @discardableResult
    public static func sweep(_ area: String, root: URL = IncognitoTemp.defaultRoot, now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let base = root.appendingPathComponent(area, isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        else { return [] }
        var removed: [URL] = []
        for item in items {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                guard !IncognitoTemp.isLive(item) else { continue }
            } else {
                guard let modified = values?.contentModificationDate, now.timeIntervalSince(modified) > looseFileAge else { continue }
            }
            if (try? fm.removeItem(at: item)) != nil { removed.append(item) }
        }
        return removed
    }
}
