// Process limits of one interpreter (M6.T18 step 1; P-files-tools-09 "RLIMITs (2 GB, 60 s, RLIMIT_FSIZE 100 MB)").
// The service passes them as ANTICHAT_LIMITS; the runtime's launcher (Runtimes/filetools-runtime/launcher/ft-python.c)
// sets soft = hard before Python starts, so neither our code nor the user's can raise them, and every process the
// code forks inherits them. RLIMIT_CPU is the interpreter's lifetime budget (repl.py lowers the soft limit to
// "used + 60 s" before each run → SIGXCPU); RLIMIT_FSIZE 100 MB makes a larger write fail with EFBIG (CPython
// ignores SIGXFSZ; C code that does not dies of it); RLIMIT_AS is set but not relied upon (macOS does not enforce
// it for mmap): the memory cap is the watchdog's footprint measurement. RLIMIT_NPROC is set to 1 by
// Launcher.bootstrap (M6.T21 review #4): the kernel compares the user's process count with the forking process's own
// limit, so the interpreter cannot fork at all and other apps are unaffected.
import AntiChatEngineProtocol
import Foundation

public struct ProcessLimits: Sendable, Equatable {
    /// Lifetime CPU seconds of the interpreter (hard RLIMIT_CPU); a run gets `runCPUSeconds` of it.
    public var cpuLifetimeSeconds: Int = 600
    public var runCPUSeconds: Int = 60
    public var fileSizeBytes: Int64 = FileToolsProtocol.maxFileBytes
    public var openFiles: Int = 256
    /// RLIMIT_AS; the enforced memory bound is `Watchdog.memoryCap`.
    public var addressSpaceBytes: Int64

    public init(memoryCap: Int64) { addressSpaceBytes = memoryCap }

    /// The launcher's ANTICHAT_LIMITS value.
    public var launcherSpec: String {
        "cpu=\(cpuLifetimeSeconds),fsize=\(fileSizeBytes),nofile=\(openFiles),core=0,as=\(addressSpaceBytes)"
    }
}
