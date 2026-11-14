// Shared helpers for the M9 accessibility / localisation UI tests (Q-015: committed, not run on this Mac; the
// in-process probe tools/at/at-223-probe.sh covers the inventory and language legs meanwhile).
import XCTest

enum A11y {
    static let symbolName = try! NSRegularExpression(pattern: "^[a-z0-9]+(\\.[a-z0-9]+)+$")

    static func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-UseScriptedEngine", "basic",
                                            "-OfflineOnly", "YES", "-FakeEvilEnabled", "YES",
                                            "-DefaultsSuite", "com.antichat.uitest.a11y"] + extra)
        app.launch()
        return app
    }

    static func element(_ root: XCUIElement, _ id: String) -> XCUIElement {
        root.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Hittable interactive elements whose label is empty, a symbol name, or the identifier itself.
    static func unlabeled(in root: XCUIElement) -> [String] {
        let types: [XCUIElement.ElementType] = [.button, .checkBox, .radioButton, .popUpButton, .menuButton,
                                                 .textField, .textView, .slider, .link, .disclosureTriangle]
        var bad: [String] = []
        // Q-015 r6: an NSScroller's page areas (AXIncrementPage / AXDecrementPage, XCUITest type Button, no title; the
        // palette's list showed them as "9 id= label=''") are AppKit's own scroll bar parts, named by their subrole,
        // like the titlebar buttons below. Narrow match: role Button, a direct child of a ScrollBar (the NSScroller),
        // no identifier and no label; matched again by frame below.
        // Reviewer: lead (orchestrator) 2026-11-11 — accepted, AppKit-owned NSScroller page buttons, same class as
        // _XCUI titlebar exclusion.
        let scrollerParts = Set(root.scrollBars.children(matching: .button).allElementsBoundByIndex
            .filter { $0.identifier.isEmpty && $0.label.isEmpty }.map { NSStringFromRect($0.frame) })
        for t in types {
            // Q-015 r5: `_XCUI:CloseWindow` / `MinimizeWindow` / `ZoomWindow` / `FullScreenWindow` are XCUITest's ids for
            // AppKit's own NSThemeFrame traffic lights (no AXTitle on macOS 26; VoiceOver names them by subrole). Not
            // our elements (same scope as the audit-ignores.yml `_XCUI:FullScreenWindow` entry). Only the `_XCUI:` prefix.
            // Reviewer: lead (orchestrator) 2026-11-11 — accepted, AppKit/XCTest-owned titlebar buttons, same scope as
            // _XCUI:FullScreenWindow.
            for e in root.descendants(matching: t).allElementsBoundByIndex where e.exists && e.isHittable && !e.identifier.hasPrefix("_XCUI:") {
                if t == .button, e.identifier.isEmpty, e.label.isEmpty, scrollerParts.contains(NSStringFromRect(e.frame)) { continue }
                let label = e.displayText.trimmingCharacters(in: .whitespaces)
                let isSymbol = symbolName.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
                let placeholder = (e.placeholderValue ?? "").isEmpty == false
                if (label.isEmpty && !placeholder) || isSymbol || (!e.identifier.isEmpty && label == e.identifier) {
                    bad.append("\(t.rawValue) id=\(e.identifier) label='\(label)'")
                }
            }
        }
        return bad
    }

    static func sendOneTurn(_ app: XCUIApplication, _ text: String = "Hello there.") {
        let composer = element(app, "composer")
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        app.typeText(text + "\r")
        XCTAssertTrue(element(app, "assistantText").waitForExistence(timeout: 30))
    }

    static func write(_ obj: Any, _ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
    }
}
