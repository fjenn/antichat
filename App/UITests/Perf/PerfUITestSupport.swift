// M9.T05 XCUITest performance legs (App/UITests/Perf/; test-strategy §6, the M1.T26b owners named in tools/perf/run.py):
// the app writes its Signposts intervals to the perf log (`ANTICHAT_PERF_LOG`, PerfRecorder) while the test drives the
// real foreground app; `make perf METRIC=<U2|U6|U10|U11> FROM_LOG=<log>` (tools/perf/run.py --from-log) computes the
// percentiles and checks the bars. The tests assert that every driven action produced its interval (a leg that
// records nothing never passes), not the bars themselves (one place judges them: run.py, with the machine load).
// Env (xcodebuild forwards TEST_RUNNER_<name> to the runner as <name>):
//   ANTICHAT_PERF_LOG      the perf log the app writes (default build/perf/raw/uitest/<suite>-<utc>.jsonl)
//   ANTICHAT_PERF_RUNS     actions per leg (default 20)
//   ANTICHAT_PERF_AT_DIR   where P3 / B5 / PR1 write their JSON (default build/at)
//   ANTICHAT_BIG10K_DB     the 10,000-chat database (default build/fixtures/big-10k.sqlite, tools/fixtures/gen-chats.py)
// Conventions: every launch is a foreground app with a throwaway container (`ANTICHAT_BACKGROUND=0`, like
// UITestSupport), the main window is found by its SwiftUI identifier `main-…` (its title is the open chat's).
import AppKit
import XCTest

enum PerfUI {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var runs: Int { env["ANTICHAT_PERF_RUNS"].flatMap(Int.init) ?? 20 }

    static func utc() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: Date())
    }

    /// The perf log of this test (one file per suite run unless ANTICHAT_PERF_LOG names one for the whole run).
    static func perfLog(_ suite: String) -> URL {
        if let p = env["ANTICHAT_PERF_LOG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return repoRoot.appendingPathComponent("build/perf/raw/uitest/\(suite)-\(utc()).jsonl")
    }

    static func atDir(_ at: String) -> URL {
        let base = env["ANTICHAT_PERF_AT_DIR"].map { URL(fileURLWithPath: $0) } ?? repoRoot.appendingPathComponent("build/at")
        let d = base.appendingPathComponent(at)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func script(_ name: String) -> String {
        let f = repoRoot.appendingPathComponent("fixtures/scripts/\(name)")
        if FileManager.default.fileExists(atPath: f.path) { return f.path }
        return repoRoot.appendingPathComponent("tools/fixtures/scripts/\(name)").path
    }

    static func tempContainer(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("antichat-uitest-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A foreground AntiChat with `container`, the perf log and `arguments`.
    @MainActor
    static func launch(container: URL, log: URL?, _ arguments: [String]) -> XCUIApplication {
        // M9.T05: `ANTICHAT_PERF_APP=<path>` (TEST_RUNNER_…) drives that bundle by URL — the optimized perf-harness
        // build (make build-perf), so the timed legs measure -O code; default the Debug app under test.
        let app = env["ANTICHAT_PERF_APP"].map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", container.path, "-ApplePersistenceIgnoreState", "YES"] + arguments
        app.launchEnvironment["ANTICHAT_BACKGROUND"] = "0"
        if let log {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            app.launchEnvironment["ANTICHAT_PERF_LOG"] = log.path
        }
        app.launch()
        app.activate()
        XCTAssertTrue(mainWindow(app).waitForExistence(timeout: 20), "no main window")
        return app
    }

    /// The main chat window (SwiftUI identifier `main-AppWindow-<n>`; `windows["AntiChat"]` never matches).
    @MainActor
    static func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-'")).firstMatch
    }

    @MainActor
    static func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    static func send(_ app: XCUIApplication, _ text: String) {
        let input = element(app, "composerText")
        XCTAssertTrue(input.waitForExistence(timeout: 15), "composer")
        input.click()
        input.typeText(text)
        input.typeKey(.return, modifierFlags: [])
    }

    /// Waits until `element` exists (true) or the timeout passes.
    @MainActor
    static func wait(_ e: XCUIElement, gone: Bool = false, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if e.exists != gone { return true }
            usleep(20_000)
        }
        return e.exists != gone
    }

    /// Records of `name` (kind interval) in the perf log.
    static func intervals(_ log: URL, _ name: String) -> [[String: Any]] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  o["name"] as? String == name, o["kind"] as? String == "interval" else { return nil }
            return o
        }
    }

    /// Waits up to `timeout` for at least `n` `name` intervals (the app writes them at the next CATransaction commit).
    static func waitIntervals(_ log: URL, _ name: String, atLeast n: Int, timeout: TimeInterval = 5) -> Int {
        let end = Date().addingTimeInterval(timeout)
        var c = intervals(log, name).count
        while c < n, Date() < end {
            usleep(100_000)
            c = intervals(log, name).count
        }
        return c
    }

    static func writeJSON(_ obj: [String: Any], to url: URL) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }

    /// One evidence line in the xcodebuild log (`AT-EVIDENCE <id> {json}`), like TurnApp.evidence.
    static func evidence(_ id: String, _ fields: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        print("AT-EVIDENCE \(id) \(String(decoding: data, as: UTF8.self))")
    }

    static func loadAverage() -> Double {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l[0]
    }
}
