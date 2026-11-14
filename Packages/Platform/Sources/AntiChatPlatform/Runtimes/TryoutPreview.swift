// Owner try-out preview only (`make build-tryout` compiles with ANTICHAT_TRYOUT_PREVIEW; release builds never do,
// see tools/ci/tryout-guard.py). The catalog's runtime URLs still point at the dev server (`make site-dev`) until the
// hosting is live, so the preview carries the signed runtime zips in its own bundle
// (`Contents/Resources/TryoutRuntimes/<name>-<version>.zip`, sha256-checked against the catalog when the try-out is
// built) and installs from there without any network. Reading the app's own bundle never asks for a folder
// permission. RuntimeInstaller verifies the sha256 again after staging, exactly as for a download.
#if ANTICHAT_TRYOUT_PREVIEW
import Foundation

enum TryoutPreview {
    /// The bundled zips, if any.
    static var bundledRuntimes: URL? {
        Bundle.main.resourceURL?.appending(path: "TryoutRuntimes", directoryHint: .isDirectory)
    }

    /// Copies the bundled zip for `request` (its pack = the runtime name, same size as the catalog entry) into
    /// `downloads` and returns the copy (the installer deletes the zip it gets); nil when the bundle has none.
    static func stageBundledRuntime(_ request: DownloadRequest, into downloads: URL) throws -> URL? {
        guard let dir = bundledRuntimes else { return nil }
        let name = request.pack
        let fm = FileManager.default
        let candidates = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("\(name)-") && $0.pathExtension == "zip" }
        guard let zip = candidates.first(where: {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == request.size
        }) else { return nil }
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let copy = downloads.appending(path: "tryout-\(UUID().uuidString.prefix(8))-\(zip.lastPathComponent)")
        try fm.copyItem(at: zip, to: copy)
        return copy
    }
}
#endif
