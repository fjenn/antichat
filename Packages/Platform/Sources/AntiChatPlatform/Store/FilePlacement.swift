// M2.T08/T10 (blueprint E §E.2.6; P-platform-04 residual): putting a blob where an engine expects a file.
// `symlink` = relative symlink into the store (the default install view, swift-huggingface HubCache snapshot layout);
// `clone` = clonefile(2) — an APFS copy-on-write clone that costs no disk, for engines that refuse symlinks
// (catalog `symlinks: false`, FluidAudio's `.mlmodelc` folders); on a volume without clones it falls back to a copy.
import Darwin
import Foundation

public enum FilePlacement: String, Sendable, Codable {
    case symlink, clone

    /// Places `blob` at `dest` (parent directories created; an existing `dest` is replaced).
    public func place(_ blob: URL, at dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? dest.checkResourceIsReachable()) == true || (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil {
            try fm.removeItem(at: dest)
        }
        switch self {
        case .symlink:
            try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: Self.relativePath(from: dest.deletingLastPathComponent(), to: blob))
        case .clone:
            if clonefile(blob.path, dest.path, 0) != 0 {
                let e = errno
                guard e == ENOTSUP || e == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO) }
                try fm.copyItem(at: blob, to: dest)  // non-APFS volume: a real copy (dedup still by sha256)
            }
            chmod(dest.path, 0o444)
        }
    }

    /// `to` relative to the directory `from` (both absolute), e.g. `../../store/sha256/ab/abcd…`.
    static func relativePath(from dir: URL, to target: URL) -> String {
        let a = dir.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let b = target.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
    }
}
