// M2.T09 step 1 (R-204 AC1, NFR-D2; hardware-tiers §5): the single disk rule — free ≥ download size + 10 GB — at every
// entry point (onboarding, pack add, Evil add, catalog update, install card), and the watcher that holds the queue
// while free space is below the 10 GB headroom. GB = 10⁹ bytes (Finder's unit). Free space =
// `volumeAvailableCapacityForImportantUsage` of the Models volume, or `-FakeFreeDiskGB <n>` (DEBUG).
import AntiChatFoundation
import Foundation

public enum DiskPreflight {
    public static let headroomBytes: Int64 = 10_000_000_000
    public static let gb: Double = 1e9

    public enum Result: Sendable, Equatable {
        case ok
        /// `gbNeeded` = whole GB more free space needed (rounded up; `download.diskFull` "Needs {gb} GB more free space.").
        case short(gbNeeded: Int)
    }

    /// The rule: `free ≥ total + 10 GB` → ok.
    public static func check(total: Int64, free: Int64) -> Result {
        let need = total + headroomBytes - free
        guard need > 0 else { return .ok }
        return .short(gbNeeded: max(1, Int((Double(need) / gb).rounded(.up))))
    }

    /// The rule against the live (or faked) free space of `volume`.
    public static func check(total: Int64, volume: URL, options: LaunchOptions = .current) -> Result {
        check(total: total, free: freeBytes(volume: volume, options: options))
    }

    /// Below the headroom alone: the watcher holds the queue (and resumes it once there is room again).
    public static func isBelowHeadroom(free: Int64) -> Bool { free < headroomBytes }

    public static func freeBytes(volume: URL, options: LaunchOptions = .current) -> Int64 {
        if let fake = options.fakeFreeDiskGB { return Int64(fake) * 1_000_000_000 }
        return HardwareProbe.freeDiskBytes(at: volume) ?? 0
    }
}
