// M6.T16 step 4 (NFR-D8 spirit): the exact bytes of installed runtime components for the Storage view (M8's
// StorageAccountant lists them; row label `storage.row.filetools` for the File tools runtime). Allocated size
// (`totalFileAllocatedSize`) summed over the tree, symlinks counted once as links — matches `du -k` within 1 %.
import AntiChatStorage
import Foundation

public struct RuntimeSpaceRow: Sendable, Equatable {
    public var name: String
    public var version: String
    /// Copy-deck key of the row label (`storage.row.<short name>`).
    public var labelKey: String
    public var bytes: Int64
}

extension SpaceAccountant {
    /// Allocated bytes of every regular file under `dir` (0 when missing).
    public static func treeAllocated(_ dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// One `runtimes` row per installed runtime, measured now (not the size recorded at install time).
    public static func runtimes(_ registry: RuntimeRegistry) -> [RuntimeSpaceRow] {
        registry.all().compactMap { r in
            let dir = URL(fileURLWithPath: r.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
            let short = r.id.hasSuffix("-runtime") ? String(r.id.dropLast("-runtime".count)) : r.id
            return RuntimeSpaceRow(name: r.id, version: r.version, labelKey: "storage.row.\(short)", bytes: treeAllocated(dir))
        }
    }
}
