// M2.T06 test support: every hardware fixture as a profile, the published catalog (baseline), and repo paths for the
// AT artefacts (build/at/AT-222, AT-NFR-D3, AT-NFR-D4).
@testable import AntiChatPlatform
import Foundation

enum SelectorFixtures {
    static let hardwareDir = HardwareProbe.fixtureURL("t0-m1-8")!.deletingLastPathComponent()
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardizedFileURL

    static var names: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: hardwareDir.path))?
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix("expected") }.map { String($0.dropLast(5)) }.sorted() ?? []
    }

    static func profile(_ name: String) throws -> HardwareProfile {
        let facts = try HardwareFacts(fixture: Data(contentsOf: hardwareDir.appending(path: "\(name).json")))
        return HardwareProfile(facts: facts, classification: TierClassifier.classify(facts: facts), fixture: name)
    }

    static func baseline() throws -> ModelCatalog { try ModelCatalog.decode(CatalogStore.bundledBaseline()!.data) }

    static func write(_ text: String, to relative: String) throws {
        let url = repo.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `T0 ≤ 4 GB · T1 ≤ 15 GB · …` for an NFR id, read from nfr.md (never retyped).
    static func caps(_ id: String) throws -> [HardwareTier: Double] {
        let nfr = try String(contentsOf: repo.appending(path: "docs/research/02-target/nfr.md"), encoding: .utf8)
        guard let line = nfr.split(separator: "\n").first(where: { $0.hasPrefix("| \(id) |") }) else { return [:] }
        var out: [HardwareTier: Double] = [:]
        let rx = try NSRegularExpression(pattern: #"(T[0-4]) ≤ ([0-9.]+) GB"#)
        let s = String(line)
        for m in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let t = String(s[Range(m.range(at: 1), in: s)!]), v = Double(s[Range(m.range(at: 2), in: s)!])!
            out[HardwareTier(rawValue: t)!] = v
        }
        return out
    }
}
