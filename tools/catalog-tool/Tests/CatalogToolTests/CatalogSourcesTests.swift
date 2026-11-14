// M2.T04 AT-300 (R-300 AC1, AC3 in its D-007 form): every `sources[]` URL of the published catalog is an anonymous
// Hugging Face commit URL (or, for an upstream only on GitHub, a commit-pinned raw URL: A-M5-11); the published catalog passes lint; the YAML inputs round-trip through the builder.
@testable import catalog_tool
import Foundation
import Testing

@Suite struct CatalogSourcesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardizedFileURL
    static var published: URL { root.appending(path: "site/public/catalog/v2/catalog.json") }

    @Test func everySourceIsAnHFCommitURL() throws {
        let m = try Manifest.load(Self.published)
        var n = 0
        for (id, e) in m.models {
            #expect(e.commit.count == 40, "\(id)")
            for f in e.files {
                for s in f.sources {
                    n += 1
                    #expect(s.range(of: Lint.sourcePattern, options: .regularExpression) != nil, "\(id): \(s)")
                    // HF `/resolve/<commit>/`; a `host: github` entry (vid-taehv, A-M5-11) `raw.githubusercontent.com/<repo>/<commit>/`.
                    #expect(s.contains("/resolve/\(e.commit)/") || s.hasPrefix("https://raw.githubusercontent.com/\(e.repo)/\(e.commit)/"), "\(id): \(s)")
                }
            }
        }
        #expect(n > 0)
    }

    @Test func publishedCatalogLintsClean() throws {
        let m = try Manifest.load(Self.published)
        let lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: Self.root.appending(path: "catalog/catalog.lock.json")))
        #expect(Lint.run(m, gated: lock.models.mapValues(\.gated)) == [])
        #expect(lock.models.values.allSatisfy { !$0.gated })
    }

    @Test func yamlInputsExpandEverySpeedClass() throws {
        let a = try Spec.assignments(Self.root.appending(path: "catalog/assignments.yaml"))
        #expect(a.cells.count == 9)
        for (k, classes) in a.cells { #expect(Set(classes.keys) == ["S1", "S2", "S3", "S4"], "\(k)") }
        #expect(a.cells["T2-24"]?["S4"]?.photo?.normal == ["img-klein-q8", "img-zit-q8", "img-erase"])  // M4.T15: + LaMa Erase
        #expect(a.cells["T2-24"]?["S3"]?.photo?.normal == ["img-klein-q8", "img-erase"])
        #expect(a.tone.hasPrefix("Answer directly and completely."))
        let specs = try Spec.models(Self.root.appending(path: "catalog/models.yaml"))
        #expect(specs.first { $0.key == "chat-0.8b" }?.license == "Apache-2.0")  // `<<: *apache` merge keys
    }

    @Test func rebuildFromLockIsByteIdentical() async throws {
        let specs = try Spec.models(Self.root.appending(path: "catalog/models.yaml"))
        let lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: Self.root.appending(path: "catalog/catalog.lock.json")))
        let published = try Manifest.load(Self.published)
        let m = try Build.manifest(specs: specs, lock: lock, assignmentsURL: Self.root.appending(path: "catalog/assignments.yaml"),
                                   issued: Date(), previous: published,
                                   searchEnginesURL: Self.root.appending(path: "catalog/search-engines.yaml"),  // M7.T01
                                   mcpCuratedURL: Self.root.appending(path: "catalog/mcp-curated.yaml"),  // M7.T06
                                   runtimes: try Spec.runtimes(Self.root.appending(path: "catalog/runtimes.yaml")))  // M6.T16
        #expect(try m.encoded() == Data(contentsOf: Self.published))
    }
}
