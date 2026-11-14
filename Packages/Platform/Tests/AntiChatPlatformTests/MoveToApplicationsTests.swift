// M10.T02 (R-225 AC3/AC5): when the Move to Applications offer may appear. LetsMove itself (copy, replace,
// relaunch, eject) is exercised in the VM (`make test-install CASE=move ENV=tart`, pending Tart); here the guard
// that keeps Debug builds and every test/probe launch from ever showing the dialog, plus the bundled English
// strings carrying the R-225 wording.
//   make test-unit FILTER=MoveToApplicationsTests
import Foundation
import Testing
@testable import AntiChatPlatform

struct MoveToApplicationsTests {
    let home = "/Users/someone"

    @Test(arguments: ["/Volumes/AntiChat/AntiChat.app", "/Users/someone/Downloads/AntiChat.app", "/tmp/x/AntiChat.app"])
    func releaseBuildOutsideApplicationsOffers(_ path: String) {
        #expect(MoveToApplicationsService.decide(bundlePath: path, debugBuild: false, backgroundLaunch: false,
                                                 flagOn: true, home: home) == .offer)
    }

    @Test(arguments: ["/Applications/AntiChat.app", "/Users/someone/Applications/AntiChat.app"])
    func alreadyInApplicationsSkips(_ path: String) {
        #expect(MoveToApplicationsService.decide(bundlePath: path, debugBuild: false, backgroundLaunch: false,
                                                 flagOn: true, home: home) != .offer)
    }

    @Test func debugBackgroundAndFlagOffNeverOffer() {
        let p = "/Volumes/AntiChat/AntiChat.app"
        #expect(MoveToApplicationsService.decide(bundlePath: p, debugBuild: true, backgroundLaunch: false, flagOn: true) != .offer)
        #expect(MoveToApplicationsService.decide(bundlePath: p, debugBuild: false, backgroundLaunch: true, flagOn: true) != .offer)
        #expect(MoveToApplicationsService.decide(bundlePath: p, debugBuild: false, backgroundLaunch: false, flagOn: false) != .offer)
    }

    @Test func englishStringsCarryTheR225Wording() throws {
        let bundle = try #require(LetsMoveStrings.bundle)
        let s = { (k: String) in bundle.localizedString(forKey: k, value: "<missing>", table: "MoveApplication") }
        #expect(s("Move to Applications folder?") == "Move AntiChat to your Applications folder?")
        #expect(s("Move to Applications Folder") == "Move to Applications")
        #expect(s("Do Not Move") == "Do Not Move")
    }
}
