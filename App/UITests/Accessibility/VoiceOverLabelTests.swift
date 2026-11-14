// AT-223 part 1 / AT-NFR-A2 (M9.T01 step 1–2): the inventory of every hittable element on the journey screens has
// 0 unlabeled elements and 0 symbol-name labels; the Evil chat's window title carries "Evil mode chat".
import XCTest

final class VoiceOverLabelTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    @MainActor
    func testInventory() throws {
        let app = A11y.launch()
        var inventory: [String: [String]] = [:]
        inventory["S-05"] = A11y.unlabeled(in: app.windows.firstMatch)
        A11y.sendOneTurn(app)
        inventory["S-08"] = A11y.unlabeled(in: app.windows.firstMatch)
        app.typeKey("k", modifierFlags: .command)
        inventory["S-18"] = A11y.unlabeled(in: app)
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for nav in settings.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.nav.'"))
            .allElementsBoundByIndex {
            nav.click()
            inventory["S-21 \(nav.identifier)"] = A11y.unlabeled(in: settings)
        }
        A11y.write(inventory, "build/at/AT-223/inventory.json")
        for (screen, bad) in inventory { XCTAssertEqual(bad, [], screen) }
    }

    @MainActor
    func testEvilTitleAnnounced() throws {
        let app = A11y.launch()
        app.typeKey("e", modifierFlags: [.command, .shift])
        let window = app.windows.firstMatch
        XCTAssertTrue(A11y.element(app, "evil.frame").waitForExistence(timeout: 5))
        XCTAssertTrue(window.title.contains("Evil mode chat") || (window.value as? String ?? "").contains("Evil mode chat"))
    }
}
