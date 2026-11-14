// M2.T08 step 7 (P-platform-03 D-11): FluidAudio never downloads on its own (`ModelHub.offlineMode = true`, set by the
// voice engine in M3); its models arrive through the DownloadCoordinator like every other file and are staged here into
// the directory FluidAudio expects (`<models dir>/<repo folderName>/<relative path>`, FluidAudio@v0.18.0
// Shared/Download/ModelHub.swift). Files are APFS clones of the store blobs (`.mlmodelc` loaders reject symlinks);
// the folder appears atomically (staged in `<dest>.staging`, then renamed), so a half-staged repo is never loadable.
import Foundation

public enum FluidAudioStager {
    /// `files` = relative path in the repo → blob URL. Replaces an existing `dir`. Refuses absolute or `..` paths.
    public static func stage(files: [String: URL], into dir: URL) throws {
        let fm = FileManager.default
        for p in files.keys where !isPlainRelativePath(p) { throw CocoaError(.fileWriteInvalidFileName, userInfo: [NSFilePathErrorKey: p]) }
        let staging = dir.deletingLastPathComponent().appending(path: dir.lastPathComponent + ".staging")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for (path, blob) in files.sorted(by: { $0.key < $1.key }) {
            try FilePlacement.clone.place(blob, at: staging.appending(path: path))
        }
        if fm.fileExists(atPath: dir.path) {
            let old = dir.deletingLastPathComponent().appending(path: dir.lastPathComponent + ".old")
            try? fm.removeItem(at: old)
            try fm.moveItem(at: dir, to: old)
            try fm.moveItem(at: staging, to: dir)
            try? fm.removeItem(at: old)
        } else {
            try fm.moveItem(at: staging, to: dir)
        }
    }

    static func isPlainRelativePath(_ p: String) -> Bool {
        !p.isEmpty && !p.hasPrefix("/") && !p.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }
}
