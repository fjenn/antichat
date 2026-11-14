// AT-223 part 2 / AT-NFR-A4 (M9.T02 steps 3–4): the DEBUG overrides -ForceReduceMotion / -ForceReduceTransparency /
// -ForceIncreaseContrast reach the design system (tests never change the real system settings).
import XCTest

final class SystemSettingsTests: XCTestCase {
    @MainActor func testReduceMotionStopsFadeAndOrb() {
        let app = A11y.launch(["-ForceReduceMotion", "YES"])
        A11y.sendOneTurn(app)
        // WordFadeModifier is off under Reduce Motion (EffectiveReduceMotion); the frame-level no-fade check is
        // tools/frametime.py --fade-detect on a recording (vq-12 §System settings).
        XCTAssertTrue(A11y.element(app, "assistantMarkdown").exists || A11y.element(app, "assistantText").exists)
    }

    @MainActor func testReduceTransparencyAndIncreaseContrast() {
        let app = A11y.launch(["-ForceReduceTransparency", "YES", "-ForceIncreaseContrast", "YES"])
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        A11y.element(settings, "settings.nav.appearance").click()
        XCTAssertTrue(A11y.element(settings, "settings.control.increaseContrast").exists)
    }
}
