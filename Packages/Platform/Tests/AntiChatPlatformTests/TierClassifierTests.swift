// AT-200 (R-200 AC2, AC3): every `fixtures/hardware/*.json` maps to its expected {tier, subband, B ±0.1 GB,
// speedClass} in `fixtures/hardware/expected.json` (computed by tools/fixtures/gen-hardware.py straight from
// hardware-tiers §2.1-§2.3, not from this classifier). The unknown chip takes its class from the MicroProbe.
import Foundation
import Testing
@testable import AntiChatPlatform

let hardwareFixtures: URL = HardwareProbe.fixtureURL("t0-m1-8")!.deletingLastPathComponent()

@Suite("TierClassifierTests") struct TierClassifierTests {
    struct Expected: Decodable { var tier: String; var subband: String?; var B: Double; var speedClass: String
        var bandwidthGBs: Double; var speedClassSource: String }

    func expected() throws -> [String: Expected] {
        try JSONDecoder().decode([String: Expected].self, from: Data(contentsOf: hardwareFixtures.appendingPathComponent("expected.json")))
    }

    @Test func everyFixtureMatchesExpected() throws {
        let exp = try expected()
        let files = try FileManager.default.contentsOfDirectory(atPath: hardwareFixtures.path)
            .filter { $0.hasSuffix(".json") && $0 != "expected.json" && $0 != "expected-selection.json" }
        #expect(files.count == 13)
        for file in files {
            let name = String(file.dropLast(5))
            let e = try #require(exp[name], "no expected row for \(name)")
            let facts = try HardwareFacts(fixture: Data(contentsOf: hardwareFixtures.appendingPathComponent(file)))
            let r = TierClassifier.classify(facts: facts)
            #expect(r.tier.rawValue == e.tier, "\(name) tier")
            #expect(r.subband == e.subband, "\(name) subband")
            #expect(abs(r.budgetGB - e.B) <= 0.1, "\(name) B \(r.budgetGB) vs \(e.B)")
            #expect(r.speedClass.rawValue == e.speedClass, "\(name) speed class")
            #expect(r.speedClassSource.rawValue == e.speedClassSource, "\(name) source")
            #expect(r.bandwidthGBs == e.bandwidthGBs, "\(name) bandwidth")
        }
    }

    @Test func unknownChipWithoutProbeIsPendingS1() throws {
        var facts = try HardwareFacts(fixture: Data(contentsOf: hardwareFixtures.appendingPathComponent("unknown-m7-32.json")))
        facts.microProbe = nil
        let r = TierClassifier.classify(facts: facts)
        #expect(r.tier == .T2 && r.speedClass == .S1 && r.speedClassSource == .pending && r.bandwidthGBs == nil)
    }

    @Test func budgetFormula() {
        #expect(TierClassifier.budgetGB(ramGB: 8, workingSetGB: 5.7) == 4.0)
        #expect(TierClassifier.budgetGB(ramGB: 128, workingSetGB: 115.45) == 111.5)
        #expect(TierClassifier.budgetGB(ramGB: 36, workingSetGB: 25.0) == 25.0)  // W is the binding term
        #expect(TierClassifier.headroomGB(ramGB: 192) == 16)
        #expect(TierClassifier.tier(ramGB: 18) == .T1 && TierClassifier.tier(ramGB: 256) == .T4)
    }

    @Test func m5BaseIsOneClassLowerBefore26_2() {
        let f = HardwareFacts(brandString: "Apple M5", memBytes: 16 << 30, gpuCores: 10, osVersion: "26.1", osBuild: "x")
        #expect(TierClassifier.classify(facts: f).speedClass == .S2)
        var g = f
        g.osVersion = "26.2.1"
        #expect(TierClassifier.classify(facts: g).speedClass == .S3)
    }

    @Test func bandwidthTableCoversEveryGeneration() {
        let t = BandwidthTable.bundled
        for chip in ["A18 Pro", "M1", "M1 Pro", "M1 Max", "M1 Ultra", "M2", "M2 Pro", "M2 Max", "M2 Ultra", "M3", "M3 Pro",
                     "M3 Max", "M3 Ultra", "M4", "M4 Pro", "M4 Max", "M5", "M5 Pro", "M5 Max", "M5 Ultra", "M6"] {
            #expect(t.lookup(chip: chip, gpuCores: nil, ramGB: 16) != nil, "\(chip)")
        }
        #expect(t.lookup(chip: "M4 Max", gpuCores: 32, ramGB: 36)?.bandwidthGBs == 410)
        #expect(t.lookup(chip: "M4 Max", gpuCores: 40, ramGB: 64)?.bandwidthGBs == 546)
        #expect(t.lookup(chip: "M7", gpuCores: 12, ramGB: 32) == nil)
    }
}
