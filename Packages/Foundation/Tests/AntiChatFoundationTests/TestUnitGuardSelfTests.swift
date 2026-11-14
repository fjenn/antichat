// Self-test of the `make test-unit` failure guard (tools/ci/test-unit.sh). Inert unless the guard's self-test sets
// ANTICHAT_TEST_GUARD_SELFTEST:
//   fail  → one recorded failure (the guard must fail the run even if `swift test` exits 0);
//   exit  → the test process ends with exit(0) mid-run, before Swift Testing prints its summary (what a stray
//           CFRunLoopStop on the main run loop did to the UI module run: `swift test` exited 0 with suites unrun).
//   make test-unit-selftest
import Foundation
import Testing

@Suite struct TestUnitGuardSelfTests {
    static let mode = ProcessInfo.processInfo.environment["ANTICHAT_TEST_GUARD_SELFTEST"]

    @Test(.enabled(if: mode == "fail")) func deliberateFailure() {
        Issue.record("deliberate failure (ANTICHAT_TEST_GUARD_SELFTEST=fail)")
    }

    @Test(.enabled(if: mode == "exit")) func deliberateSilentExit() async {
        try? await Task.sleep(for: .milliseconds(200))
        exit(0)
    }
}
