// M4.T02/T03 (R-285 AC3, AT-285 AC3): the ChildSafetyCheck detectors are catalog entries pinned by commit + sha256,
// with licences, in the `csam_check` slot of every cell; no other catalog entry is a classifier.
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite struct CatalogChildSafetyEntryTests {
    static let detectors = ["csc-nudity", "csc-age", "csc-age-bins"]

    @Test func entriesArePinnedAndLicensed() throws {
        let c = try SelectorFixtures.baseline()
        for id in Self.detectors {
            let m = try #require(c.models[id], "\(id) missing from the baseline catalog")
            #expect(m.role == "csam_check")
            #expect(m.commit.count == 40 && m.commit.allSatisfy(\.isHexDigit), "\(id): commit pin")
            #expect(!m.files.isEmpty)
            for f in m.files { #expect(f.sha256.count == 64 && f.size > 0, "\(id)/\(f.path)") }
            #expect(m.license != nil && m.licenseURL != nil && m.attribution != nil, "\(id): licence record")
        }
        #expect(c.models["csc-nudity"]?.requires == ["csc-age", "csc-age-bins"])
        // The body-only age-bin signal (A-M4-T02b): the pinned safetensors, run by the package with Accelerate.
        #expect(c.models["csc-age-bins"]?.files.contains {
            $0.path == "model.safetensors" && $0.sha256 == "7e0205ae229b38817996d56b5106c6843cfa6c93eb460b43e85f8a8d2fabf90a"
        } == true)
        #expect(c.models["csc-nudity"]?.files.contains { $0.path == "onnx/model.onnx" } == true)  // fp32, A-M0-T08a
    }

    @Test func everyCellAssignsTheCheck() throws {
        let c = try SelectorFixtures.baseline()
        for (cell, classes) in c.assignments {
            for (sc, a) in classes { #expect(a.csamCheck == "csc-nudity", "\(cell)/\(sc)") }
        }
    }

    @Test func noOtherClassifierInTheCatalog() throws {
        let c = try SelectorFixtures.baseline()
        let classifier = try Regex("(?i)nsfw|safety|guard|toxic|moderation|detox|harm")
        for (id, m) in c.models where !id.hasPrefix("csc-") {
            #expect(m.role != "csam_check", "\(id)")
            #expect(m.repo.firstMatch(of: classifier) == nil, "\(id): \(m.repo)")
        }
    }
}

/// About → Licences reads its model rows from the catalog's licence records (the page itself is M10).
@Suite struct LicenceListTests {
    @Test func testChildSafetyDetectorsListed() throws {
        let c = try SelectorFixtures.baseline()
        let rows = c.models.values.filter { $0.license != nil }.map(\.id)
        for id in CatalogChildSafetyEntryTests.detectors { #expect(rows.contains(id), "\(id) not in the licence rows") }
        #expect(c.models["csc-nudity"]?.license == "MIT" && c.models["csc-age"]?.license == "Apache-2.0")
        #expect(c.models["csc-age-bins"]?.license == "Apache-2.0")
    }
}
