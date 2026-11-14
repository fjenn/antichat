// AT-222 part 2 UI leg (M2.T07; R-222 AC2–AC4): Settings › Capabilities › Advanced on `-FakeHardware t1-m2-16` —
// pick chat-4b → Fits; chat-35b-q4 → Too large, disabled; allow-over on → selectable; Reset to recommended; keep-loaded
// and allow-over live in Advanced, defaults 15 min / off. Screenshots build/at/AT-222/advanced-{light,dark}.png.
// Committed, not run on this Mac (Q-015: XCUITest cannot enable automation mode); OverrideSurvivesUpdateTests covers
// the same rules in-process meanwhile.
import XCTest

final class AdvancedOverrideUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func launch(_ appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", "com.antichat.uitest.advanced",
                                            "-UseScriptedEngine", "basic", "-OfflineOnly", "YES", "-FakeHardware", "t1-m2-16",
                                            "-colorMode", appearance])
        app.launch()
        return app
    }

    func el(_ root: XCUIElement, _ id: String) -> XCUIElement { root.descendants(matching: .any).matching(identifier: id).firstMatch }

    @MainActor
    func testOverridePickerFitPillsAndReset() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance)
            app.typeKey(",", modifierFlags: .command)
            let w = app.windows.containing(.any, identifier: "settings.root").firstMatch
            XCTAssertTrue(w.waitForExistence(timeout: 3))
            el(w, "settings.nav.capabilities").click()
            el(w, "settings.row.capabilities.advanced").clickDisclosure()
            // Q-015 r5: the group opens at the bottom of the Form, which builds rows below the fold lazily.
            w.scrollViews.matching(identifier: "settings.detail.capabilities").firstMatch.scrollUntilVisible(el(w, "settings.control.keepLoadedMinutes"))
            XCTAssertTrue(el(w, "settings.control.keepLoadedMinutes").waitForExistence(timeout: 2))
            XCTAssertEqual(el(w, "settings.control.allowOverBudget").value as? Int, 0)
            let picker = el(w, "override.chat.normal")
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.click()
            // ee30e26c4 (VQ S-21): the picker lists published model names, not catalog keys —
            // chat-35b-q4 is "Qwen3.6-35B-A3B · 4-bit" (its 6/8-bit siblings share the name, so the precision tells
            // them apart), chat-4b is "Qwen3.5-4B" (catalog attribution).
            let big = "Qwen3.6-35B-A3B · 4-bit", small = "Qwen3.5-4B"
            XCTAssertTrue(app.menuItems[big].exists)
            XCTAssertFalse(app.menuItems[big].isEnabled, "Too large is disabled while allow-over is off")
            app.menuItems[small].click()
            XCTAssertTrue(el(w, "fitPill.fits").exists)
            let shot = w.screenshot()
            let url = URL(fileURLWithPath: "build/at/AT-222/advanced-\(appearance).png")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try shot.pngRepresentation.write(to: url)
            el(w, "settings.control.allowOverBudget").click()
            picker.click()
            XCTAssertTrue(app.menuItems[big].isEnabled)
            app.typeKey(.escape, modifierFlags: [])
            el(w, "override.reset.chat").click()
            XCTAssertFalse(el(w, "override.reset.chat").exists)
            el(w, "settings.control.allowOverBudget").click()
            app.terminate()
        }
    }
}
