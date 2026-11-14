// AT-207 UI leg (M2.T14; R-207 AC1–AC3): Settings › General › Performance has Auto / Maximum / Battery saver;
// `-FakePower battery:15` with Auto → Battery saver in effect and the `power.saver.on` line; `-FakeThermal serious` →
// the `power.cooler` line. (`-FakePower battery:8` → the download StatusPill paused is DownloadPolicy's, AT-204.)
// Committed, not run on this Mac (Q-015); PowerPolicyTests / ThermalPolicyTests cover the decisions in-process.
import XCTest

final class PerformancePickerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func el(_ root: XCUIElement, _ id: String) -> XCUIElement { root.descendants(matching: .any).matching(identifier: id).firstMatch }

    @MainActor
    func openGeneral(_ args: [String]) -> XCUIElement {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", "com.antichat.uitest.perf",
                                            "-UseScriptedEngine", "basic", "-performance", "auto"] + args)
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        let w = app.windows.containing(.any, identifier: "settings.root").firstMatch
        el(w, "settings.nav.general").click()
        return w
    }

    @MainActor
    func testLowBatteryAutoShowsBatterySaver() {
        let w = openGeneral(["-FakePower", "battery:15"])
        XCTAssertTrue(el(w, "settings.control.performance").waitForExistence(timeout: 10))
        XCTAssertTrue(el(w, "power.saver.on").waitForExistence(timeout: 5))
    }

    @MainActor
    func testACAutoHasNoNotice() {
        let w = openGeneral(["-FakePower", "ac"])
        XCTAssertTrue(el(w, "settings.control.performance").waitForExistence(timeout: 10))
        XCTAssertFalse(el(w, "power.saver.on").exists)
    }

    @MainActor
    func testSeriousThermalShowsCoolerNotice() {
        let w = openGeneral(["-FakePower", "ac", "-FakeThermal", "serious"])
        XCTAssertTrue(el(w, "power.cooler").waitForExistence(timeout: 10))
    }
}
