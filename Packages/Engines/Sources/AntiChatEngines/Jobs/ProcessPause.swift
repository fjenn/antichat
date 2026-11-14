// M5.T11 (NFR-B3, NFR-B5): pausing and de-prioritising a media job's child process (the video runtime server or
// sd-server). Pause = SIGSTOP / SIGCONT of the child's process (never its group: the helper's watchdog children keep
// running), only ever sent at a step boundary by VideoJobGovernor (a SIGSTOP in the middle of a Metal command buffer
// leaves the GPU busy — M5.md T11 failure mode). Background = `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`:
// CPU and I/O at background (≈ `.utility` QoS or lower) and GPU work at background priority, undone with 0.
import Darwin
import Foundation

public enum ProcessPause {
    /// SIGSTOP. False when the process is gone or not our unreaped child (fix/stray-kill: a pid kept after the child
    /// was reaped may name an unrelated process by now; `OwnChild` proves it is still ours).
    @discardableResult
    public static func stop(_ pid: pid_t) -> Bool {
        guard OwnChild.isUnreaped(pid) else { return false }
        return kill(pid, SIGSTOP) == 0
    }

    /// SIGCONT (a running process ignores it); only to our unreaped child, like `stop`.
    @discardableResult
    public static func resume(_ pid: pid_t) -> Bool {
        guard OwnChild.isUnreaped(pid) else { return false }
        return kill(pid, SIGCONT) == 0
    }

    /// Darwin background priority on (`PRIO_DARWIN_BG`) or off (0).
    @discardableResult
    public static func setBackground(_ pid: pid_t, _ on: Bool) -> Bool {
        guard OwnChild.isUnreaped(pid) else { return false }
        return setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0
    }

    /// True when the process runs at Darwin background priority: its task's base priority drops from the default
    /// 31 to 4 (`proc_pidinfo` PROC_PIDTASKINFO; `getpriority(PRIO_DARWIN_PROCESS, pid)` reads 0 for other processes).
    public static func isBackground(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var ti = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        return n == Int32(MemoryLayout<proc_taskinfo>.size) && ti.pti_priority < 20
    }

    /// The process state letter from `proc_pidinfo` (`T` = stopped), nil when gone. Tests and diagnostics.
    public static func isStopped(_ pid: pid_t) -> Bool? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return info.pbi_status == UInt32(SSTOP)
    }
}
