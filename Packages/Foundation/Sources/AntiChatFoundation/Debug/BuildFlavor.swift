// M9.T05: what this binary was compiled as, for the perf harness (`AntiChat -Bench buildinfo`, tools/perf/run.py).
// `ANTICHAT_PERF_HARNESS` is the optimized perf build (`make build-perf`, tools/perf/build-perf.sh): Release
// configuration (-O, NDEBUG, no DEBUG) with the test hooks the T05 probes need (`#if DEBUG || ANTICHAT_PERF_HARNESS`:
// `-ANTICHAT_DEV_CONTAINER`, launch options, scripted inputs, probes). It never ships: tools/ci/perfharness-guard.py
// (make audit, release preflight) fails a release/devid build that carries the flag or the marker below.
import Foundation

public enum BuildFlavor {
    public static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static var isPerfHarness: Bool {
        #if ANTICHAT_PERF_HARNESS
        true
        #else
        false
        #endif
    }

    /// False in an -Onone build (the stdlib's debug-assert configuration), true with -O / -Osize.
    public static var isOptimized: Bool { !_isDebugAssertConfiguration() }

    #if ANTICHAT_PERF_HARNESS
    /// The byte marker perfharness-guard.py looks for in a built bundle (present only in a perf-harness binary).
    public static let perfHarnessMarker = "AntiChatPerfHarnessBuild-M9T05"
    #endif

    /// `-Bench buildinfo`: one JSON line, read by tools/perf/run.py before it calls a measurement valid.
    public static var json: String {
        var marker = ""
        #if ANTICHAT_PERF_HARNESS
        marker = perfHarnessMarker
        #endif
        return "{\"debug\":\(isDebug),\"perf_harness\":\(isPerfHarness),\"optimized\":\(isOptimized),\"marker\":\"\(marker)\"}"
    }
}
