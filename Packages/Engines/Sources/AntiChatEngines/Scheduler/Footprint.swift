// M2.T12 step 2 (R-206 AC1, G-011 risk note): memory accounting. Four engines report memory differently, so each
// resident model counts max(measured, catalog footprint) — the catalog's static footprint is the floor. Process
// usage = phys_footprint of the helper + each llama-server child PID (one per resident GGUF), plus
// MTLDevice.currentAllocatedSize for the in-process Metal heaps (MemoryProbe).
import Darwin
import Foundation

public enum Footprint {
    /// `ri_phys_footprint` of a process (0 for pid ≤ 0 or an exited process).
    public static func phys(_ pid: pid_t) -> UInt64 {
        guard pid > 0 else { return 0 }
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }

    /// helper + children (the llama-server PIDs of the resident GGUF models).
    public static func processUsage(helper: pid_t = getpid(), children: [pid_t]) -> UInt64 {
        children.reduce(phys(helper)) { $0 + phys($1) }
    }

    /// The figure the fit rule uses for one model: never below the catalog footprint.
    public static func effective(measured: UInt64, catalog: UInt64) -> UInt64 { max(measured, catalog) }
}
