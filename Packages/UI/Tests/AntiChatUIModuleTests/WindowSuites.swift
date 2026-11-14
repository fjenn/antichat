// One serialized parent for every suite that puts AppKit windows or hosting views up (make test-unit runs the
// module's suites in parallel in ONE process, so they all share the main thread). Under the full parallel load the
// window suites kept the main actor busy with layout for seconds at a time: scripted turns in the host tests
// (TurnQueueHost, IncognitoWindow, ThinkHarderHost — all three nested here now: a run loop spun inside a main-actor
// job does not drain the main queue, so a turn beside a spinning suite waits out every spin) could not finish inside
// 30 s and first renders of the goldens
// raced font loading. `.serialized` applies to nested suites, so the suites declared in `extension WindowSuites`
// run one after another; logic-only suites stay parallel. Filters still match by suite name
// (`make test-unit FILTER=ThinkHarderHostTests`).
//
// `.mainLoopGuard`: a test process has no `NSApp.run`; Swift Testing's main thread runs one outermost
// CFRunLoopRun and calls exit(0) when it returns. AppKit / SwiftUI post CFRunLoopStop requests to the main run loop
// (measured: ~30 per handful of window suites, from blocks run in `__CFRunLoopDoBlocks`); they are meant for the
// nested runs that tests and AppKit spin (RunLoop.main.run(until:), button tracking, blocking animations), but one
// that lands while only the outermost run is active ended it — the process exited 0 mid-run with the remaining
// suites never run and `swift test` still exited 0 (tools/ci/test-unit.sh now catches that). The guard counts run
// levels with an entry/exit observer and, when the outermost run exits, re-enters it from the exit callout, so a
// stray stop costs one loop iteration instead of the rest of the run. Process exit is unaffected (Swift Testing
// calls exit() from a main-queue job when the run ends).
//
// `.backgroundRun` (the owner uses the Mac while the tests run): the window suites run with AntiChatUI's
// `BackgroundRun` on (activation policy `.prohibited`, every window concealed, no key window, input only through
// `sendEvent` to the test's own window). A sampler checks every 50 ms for the whole parent suite, and before and after
// every test, that neither this test process nor its `swift test` parent is ever the frontmost / active app; any
// sample that is fails the run (`FrontmostGuard`).
@testable import AntiChatUI
import AppKit
import Darwin
import Testing

@Suite(.serialized, .mainLoopGuard, .backgroundRun, .isolatedSettings) enum WindowSuites {}

/// Samples the frontmost application from a background queue (NSWorkspace's KVO-backed value, no main thread needed).
final class FrontmostGuard: @unchecked Sendable {
    static let shared = FrontmostGuard()
    private let lock = NSLock()
    private var violations: [String] = []
    private var timer: DispatchSourceTimer?
    private var samples = 0
    /// This process and its parent (the `swift test` driver).
    let forbidden: Set<pid_t> = [getpid(), getppid()]

    /// The violation for one sample, nil when fine (pure, so the guard itself is unit-tested).
    static func violation(frontmost: pid_t?, frontmostName: String?, selfActive: Bool, forbidden: Set<pid_t>,
                          when: String) -> String? {
        if selfActive { return "\(when): the test process is the active app" }
        if let pid = frontmost, forbidden.contains(pid) {
            return "\(when): frontmost app is the test runner (\(frontmostName ?? "?"), pid \(pid))"
        }
        return nil
    }

    func sample(_ when: String) {
        let front = NSWorkspace.shared.frontmostApplication
        let v = Self.violation(frontmost: front?.processIdentifier, frontmostName: front?.localizedName,
                               selfActive: NSRunningApplication.current.isActive, forbidden: forbidden, when: when)
        lock.lock(); samples += 1; if let v, violations.count < 20 { violations.append(v) }; lock.unlock()
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.sample("sampler") }
        t.resume()
        timer = t
    }

    func stop() -> (samples: Int, violations: [String]) {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil
        return (samples, violations)
    }

    var currentViolations: [String] { lock.lock(); defer { lock.unlock() }; return violations }
}

struct BackgroundRunTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }  // the parent scope starts the sampler; every test is checked before and after

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let g = FrontmostGuard.shared
        let isParent = test.isSuite && test.name == "WindowSuites"
        await MainActor.run { BackgroundRun.enable() }
        if isParent { g.start() }
        g.sample("before \(test.name)")
        let before = g.currentViolations.count
        try await function()
        let active = await MainActor.run { NSApp.isActive }
        if active { Issue.record("\(test.name): NSApp became active during a background window test") }
        g.sample("after \(test.name)")
        if isParent {
            let (n, violations) = g.stop()
            #expect(n > 0, "the frontmost sampler never ran")
            #expect(violations.isEmpty, "AntiChat tests came to the front: \(violations)")
        } else if !test.isSuite {
            let v = g.currentViolations.dropFirst(before)
            #expect(v.isEmpty, "AntiChat tests came to the front: \(Array(v))")
        }
    }
}

extension Trait where Self == BackgroundRunTrait {
    static var backgroundRun: Self { BackgroundRunTrait() }
}

@MainActor
enum MainLoopGuard {
    private static var installed = false
    private static var depth = 1  // installed from inside the outermost run
    private static var reentering = false

    static func install() {
        guard !installed else { return }
        installed = true
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
            MainActor.assumeIsolated {
                if activity == .entry { depth += 1; return }
                depth -= 1
                guard depth == 0, !reentering else { return }
                reentering = true
                defer { reentering = false }
                while depth == 0 {  // the outermost run was stopped: keep the main thread running
                    CFRunLoopRunInMode(.defaultMode, 0.05, true)
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

struct MainLoopGuardTrait: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }  // once, around the whole parent suite (the guard is process-wide)

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        await MainActor.run { MainLoopGuard.install() }
        try await function()
    }
}

extension Trait where Self == MainLoopGuardTrait {
    static var mainLoopGuard: Self { MainLoopGuardTrait() }
}
