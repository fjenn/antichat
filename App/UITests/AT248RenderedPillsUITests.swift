// AT-248 c1 (M7 at248): the rendered-pill reader. The app's in-process SearchProbe `live` leg drives the 20 search
// turns (tools/at/at-248-live.sh with READER=1 launches it foreground, `ANTICHAT_BACKGROUND=0`); this test launches
// that app and, after each run's citations have settled (`<dir>/settled-<i>.json`), counts the citation pills
// in the accessibility tree of the real window — what VoiceOver reads, independent of the app's own probe anchors —
// and saves a screenshot of the window. A pill still in the checking state (label "…, Checking this source…" or the
// `.checking` probe id) is not counted. Output per run: `<dir>/reader-<i>.json` + `<dir>/reader-<i>.png`, then the
// `<dir>/ack-<i>` file that lets the probe go on. The runner is sandboxed (read-only outside its container), so these
// go to `<runner tmp>/at248-<basename of dir>/` (the probe reads `<dir>/reader-dir`, the script copies them back). Env: ANTICHAT_AT248_DIR (xcodebuild: TEST_RUNNER_ANTICHAT_AT248_DIR).
// Skipped unless that variable is set (never part of the plain UI suite).
import AppKit
import XCTest

final class AT248RenderedPillsUITests: XCTestCase {
    @MainActor
    func testCountRenderedPillsPerRun() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["ANTICHAT_AT248_DIR"], !path.isEmpty else { throw XCTSkip("ANTICHAT_AT248_DIR not set") }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let runs = Int((try? String(contentsOf: dir.appendingPathComponent("runs"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 20
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("at248-\(dir.lastPathComponent)", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // The reader launches the exact bundle the script verified (`<dir>/launch-app`, by URL: a bundle-id attach can
        // resolve to another AntiChat build on this Mac) with the probe's arguments (`<dir>/launch-args`, one per line),
        // foreground (`ANTICHAT_BACKGROUND=0`).
        let appPath = try String(contentsOf: dir.appendingPathComponent("launch-app"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let args = try String(contentsOf: dir.appendingPathComponent("launch-args"), encoding: .utf8)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        if env["ANTICHAT_AT248_ATTACH"] == "1" {
            // The script started that bundle itself (foreground): attach to it by URL, never launch another copy (a
            // launch fails while other AntiChat dev builds with the same bundle id run, e.g. hosted test suites).
            let up = Date().addingTimeInterval(120)
            while app.state == .notRunning, Date() < up { usleep(500_000) }
            guard app.state != .notRunning else { XCTFail("attach: \(appPath) is not running"); return }
        } else {
            app.launchArguments = args
            app.launchEnvironment["ANTICHAT_BACKGROUND"] = "0"
            app.launch()
        }
        app.activate()
        let window = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 60), "attach: no main window of the running app")
        try Data().write(to: out.appendingPathComponent("reader-ready"))
        var counts: [Int] = []
        for i in 0..<runs {
            let settled = dir.appendingPathComponent("settled-\(i).json")
            let end = Date().addingTimeInterval(900)
            while !FileManager.default.fileExists(atPath: settled.path), Date() < end { usleep(200_000) }
            guard FileManager.default.fileExists(atPath: settled.path) else { XCTFail("run \(i): the probe never settled"); break }
            // The settled marker comes after the probe saw no checking pill for 1 s; give AX one more beat.
            usleep(500_000)
            let pills = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'citation.'"))
            var settledPills: [[String: String]] = [], checking = 0
            for e in pills.allElementsBoundByIndex where e.exists {
                let id = e.identifier, label = e.label
                if id.hasSuffix(".checking") || label.contains("Checking this source") { checking += 1; continue }
                settledPills.append(["id": id, "label": label, "type": "\(e.elementType.rawValue)",
                                     "frame": NSStringFromRect(e.frame)])
            }
            let shot = window.screenshot()
            try? shot.pngRepresentation.write(to: out.appendingPathComponent("reader-\(i).png"))
            let row: [String: Any] = ["run": i, "pills_rendered_ax": settledPills.count, "pills_checking_ax": checking,
                                      "pills": settledPills, "screenshot": "reader-\(i).png"]
            if let d = try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: out.appendingPathComponent("reader-\(i).json"))
            }
            counts.append(settledPills.count)
            print("AT-EVIDENCE AT-248-c1-reader run=\(i) pills=\(settledPills.count) checking=\(checking)")
            try Data().write(to: out.appendingPathComponent("ack-\(i)"))
        }
        print("AT-EVIDENCE AT-248-c1-reader counts=\(counts)")
        // The probe quits the app after its last run (probe.json); wait for that so the test never kills it early.
        let quit = Date().addingTimeInterval(120)
        while app.state != .notRunning, Date() < quit { usleep(500_000) }
    }
}
