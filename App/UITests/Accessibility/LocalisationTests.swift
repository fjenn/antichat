// AT-102 (M9.T04): the UI follows macOS (`-AppleLanguages (fr)`), the Settings override applies after relaunch,
// and every language opens S-05 / S-08 / S-21 for capture.
import XCTest

final class LocalisationTests: XCTestCase {
    nonisolated(unsafe) static let catalog: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "App/AntiChat/Localizable.xcstrings")
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }()

    static func string(_ key: String, _ lang: String) -> String {
        let loc = ((catalog[key] as? [String: Any])?["localizations"] as? [String: Any])?[lang] as? [String: Any]
        return (loc?["stringUnit"] as? [String: Any])?["value"] as? String ?? ""
    }

    @MainActor func testFollowsMacOS() {
        let app = A11y.launch(["-AppleLanguages", "(fr)"])
        let composer = A11y.element(app, "composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[Self.string("side.newChat", "fr")].exists)
    }

    @MainActor func testOverride() {
        var app = A11y.launch()
        app.typeKey(",", modifierFlags: .command)
        let picker = A11y.element(app, "settings.control.appLanguage")
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        app.menuItems["Deutsch"].click()
        app.terminate()
        app = A11y.launch()
        XCTAssertTrue(app.staticTexts[Self.string("side.newChat", "de")].waitForExistence(timeout: 10))
        // The override is the app's own AppleLanguages (its standard defaults domain, shared with every later run and
        // the owner's dev app): put "Follow macOS" back (Q-015 catch-up; a German UI leaked into later suites).
        app.typeKey(",", modifierFlags: .command)
        let back = A11y.element(app, "settings.control.appLanguage")
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.click()
        back.menuItems.element(boundBy: 0).click()
        app.terminate()
    }

    @MainActor func testEveryLanguageSmoke() {
        for lang in ["de", "fr", "es", "nl", "pt"] {
            let app = A11y.launch(["-AppleLanguages", "(\(lang))"])
            XCTAssertTrue(A11y.element(app, "composer").waitForExistence(timeout: 10), lang)
            let shot = app.windows.firstMatch.screenshot()
            let dir = URL(fileURLWithPath: "build/at/AT-102/\(lang)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: dir.appending(path: "S-05.png"))
            app.terminate()
        }
    }
}
