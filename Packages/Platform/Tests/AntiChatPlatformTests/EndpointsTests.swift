// M10.T05 hosting switch: Debug builds read the `<Key>Dev` twin (local site), Release builds the production value
// written from Config/Hosting.json; the committed plist has a Dev twin for every host a Debug build talks to.
//   make test-unit FILTER=EndpointsTests
import Foundation
import Testing
@testable import AntiChatPlatform

struct EndpointsTests {
    let d: [String: Any] = ["CatalogURL": "https://site/catalog/v2/catalog.json",
                            "CatalogURLDev": "http://localhost:4321/catalog/v2/catalog.json",
                            "AppcastURL": "https://site/appcast.xml"]

    @Test func debugPrefersTheDevTwin() {
        #expect(Endpoints.resolve("CatalogURL", in: d, debug: true) == "http://localhost:4321/catalog/v2/catalog.json")
        #expect(Endpoints.resolve("CatalogURL", in: d, debug: false) == "https://site/catalog/v2/catalog.json")
        #expect(Endpoints.resolve("AppcastURL", in: d, debug: true) == "https://site/appcast.xml")  // no twin
        #expect(Endpoints.resolve("Missing", in: d, debug: false) == nil)
    }

    @Test func committedPlistKeepsDebugOnTheLocalSite() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Config/Endpoints.plist").standardized
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        for key in ["CatalogURL", "DownloadURL"] {
            #expect(Endpoints.resolve(key, in: plist, debug: true)?.hasPrefix("http://localhost:4321") == true, "\(key)")
            #expect(Endpoints.resolve(key, in: plist, debug: false)?.hasPrefix("https://") == true, "\(key)")
        }
    }
}
