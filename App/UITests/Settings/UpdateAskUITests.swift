// AT-294 UI leg (M2.T11; R-294 AC4, R-220 AC2): `catalog-upgrade-big` (+2.5 GB claimed) → Capabilities shows the offer
// row "A better Chat model is available (…). Update now?" with [Update] [Later]; with "Update models automatically"
// off even a small update (`catalog-upgrade`) asks instead of downloading. Serve the fixture pair with
// `python3 -I -m http.server` (see vq-10 § Updates); tools/ci/with-catalog-fixtures.sh does it for `make test-ui` (Q-015 r4). Committed, not run on this Mac (Q-015); ModelUpdateServiceTests
// covers the same policy in-process.
import XCTest

final class UpdateAskUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func el(_ root: XCUIElement, _ id: String) -> XCUIElement { root.descendants(matching: .any).matching(identifier: id).firstMatch }

    func launch(catalog: String, autoUpdate: Bool) throws -> XCUIApplication {
        let env = ProcessInfo.processInfo.environment
        let port = env["ANTICHAT_CATALOG_PORT"] ?? "4399"
        // Q-015 r5: an offer upgrades an installed slot; the wrapper seeds a container with the Chat starter installed
        // (tools/ci/with-catalog-fixtures.sh). Without it there is nothing to offer an update for.
        let containers = try XCTUnwrap(env["ANTICHAT_UPDATE_CONTAINERS"],
                                       "precondition: a container with chat-0.8b installed (run under tools/ci/with-catalog-fixtures.sh)")
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-DefaultsSuite", "com.antichat.uitest.updates", "-FreshDefaultsSuite", "YES",
                                            "-ANTICHAT_DEV_CONTAINER", "\(containers)/\(catalog)",
                                            "-UseScriptedEngine", "basic", "-FakeHardware", "t1-m2-16", "-FakeNetwork", "ok",
                                            // catalog-upgrade-big claims a 5 TB file (fixtures/catalog/SOURCES.md): on a
                                            // real disk NFR-D2 (free ≥ extra + 10 GB) says "Needs … more free space"
                                            // before any offer; ModelUpdateServiceTests asks with 10 TB free too.
                                            "-FakeFreeDiskGB", "10000",
                                            "-CatalogURL", "http://127.0.0.1:\(port)/\(catalog)/catalog.json",
                                            "-autoUpdateModels", autoUpdate ? "YES" : "NO"])
        app.launch()
        return app
    }

    @MainActor
    func testBigUpdateAsks() throws {
        let app = try launch(catalog: "catalog-upgrade-big", autoUpdate: true)
        app.typeKey(",", modifierFlags: .command)
        let w = app.windows.containing(.any, identifier: "settings.root").firstMatch
        el(w, "settings.nav.capabilities").click()
        let row = el(w, "updateOffer.chat/normal/chat_fast")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(el(w, "updateOffer.update").exists)
        el(w, "updateOffer.later").click()
        XCTAssertFalse(row.exists)
    }

    @MainActor
    func testAutoUpdateOffAsksInsteadOfDownloading() throws {
        let app = try launch(catalog: "catalog-upgrade", autoUpdate: false)
        app.typeKey(",", modifierFlags: .command)
        let w = app.windows.containing(.any, identifier: "settings.root").firstMatch
        el(w, "settings.nav.general").click()
        XCTAssertEqual(el(w, "settings.control.autoUpdateModels").value as? Int, 0)
        el(w, "settings.nav.capabilities").click()
        XCTAssertTrue(el(w, "updateOffer.chat/normal/chat_fast").waitForExistence(timeout: 10))
    }
}
