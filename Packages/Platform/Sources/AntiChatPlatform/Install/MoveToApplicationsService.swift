// M10.T02 step 4/6 (R-225 AC3, AC5; P-platform-13): offer to move AntiChat into Applications before anything else
// (onboarding waits behind it). The move itself is LetsMove's `PFMoveToApplicationsFolderIfNecessary()` (vendored,
// public domain): it asks "Move AntiChat to your Applications folder?" (English strings patched, UP-LM-001),
// copies to /Applications (or ~/Applications), replaces an older copy after its own confirmation, relaunches from
// there and ejects the DMG it ran from. AppDelegate calls `runIfNeeded` first in applicationWillFinishLaunching.
// Skipped for Debug builds, background/test launches (BackgroundRun: probes, dev containers, XCTest hosts) and
// `ff.moveToApplications = NO` (rollback).
import AntiChatFoundation
import Foundation
import LetsMoveVendored

public enum MoveToApplicationsService {
    public enum Decision: Equatable, Sendable {
        case offer
        case skip(String)
    }

    /// Pure decision (unit-tested). LetsMove re-checks the location itself; this only keeps tests and dev
    /// builds from ever seeing the dialog.
    public static func decide(bundlePath: String, debugBuild: Bool, backgroundLaunch: Bool, flagOn: Bool,
                              home: String = NSHomeDirectory()) -> Decision {
        if debugBuild { return .skip("debug build") }
        if backgroundLaunch { return .skip("background/test launch") }
        if !flagOn { return .skip("ff.moveToApplications off") }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        if parent == "/Applications" || parent == (home as NSString).appendingPathComponent("Applications") {
            return .skip("already in Applications")
        }
        return .offer
    }

    /// Call first in `applicationWillFinishLaunching` (before onboarding windows exist).
    @MainActor
    public static func runIfNeeded(backgroundLaunch: Bool) {
        // M9.T05: the perf-harness build (a foreground test launch from build/perf-app) never offers the move either.
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let debug = true
        #else
        let debug = false
        #endif
        let d = decide(bundlePath: Bundle.main.bundlePath, debugBuild: debug, backgroundLaunch: backgroundLaunch,
                       flagOn: FeatureFlag.moveToApplications.isEnabled())
        guard d == .offer else { return }
        PFMoveToApplicationsFolderIfNecessary()
    }
}

/// The vendored LetsMove strings bundle (UP-LM-002), for the R-225 wording check.
enum LetsMoveStrings {
    static var bundle: Bundle? { PFMoveApplicationStringsBundle() }
}
