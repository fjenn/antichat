// M2.T10 step 5 (R-293 AC2): the exact "frees X GB" — Σ allocated size (`totalFileAllocatedSize`) of the blobs that
// only the removal set references. A blob shared with any install that stays (Normal ↔ Evil tokenizers, packs sharing
// an encoder) frees nothing. Matches `du` within ±1 % (FreesExactTests, tools/at/at-293-frees.sh).
import Foundation

public enum SpaceAccountant {
    /// Bytes freed by removing the install views `removal` (model ids) and collecting their blobs.
    public static func frees(_ removal: Set<String>, models: ModelsDirectory) -> Int64 {
        let all = models.installedManifests()
        let leaving = all.filter { removal.contains($0.modelID) }.flatMap(\.blobs)
        let staying = Set(all.filter { !removal.contains($0.modelID) }.flatMap(\.blobs))
        let store = BlobStore(models: models)
        return Set(leaving).subtracting(staying).reduce(Int64(0)) { $0 + allocated(store.url($1)) }
    }

    /// On-disk allocation of a file (0 when missing).
    public static func allocated(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
    }
}
