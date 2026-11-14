// M7.T01 step 6 (R-253, R-248 AC2): `catalog/search-engines.yaml` compiles into the `search_engines` section with
// sorted keys, the five default engines enabled, Bing shipped disabled, no Google id; a Google entry is refused.
@testable import catalog_tool
import Foundation
import Testing

struct SearchEnginesSectionTests {
    static let repo: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    @Test func yamlCompilesToTheSection() throws {
        let section = try #require(try Build.searchEngines(Self.repo.appending(path: "catalog/search-engines.yaml")))
        var enabled: [String] = [], all: [String] = []
        for case .object(let o) in section {
            guard case .string(let id) = o["id"], case .bool(let on) = o["enabled"] else { Issue.record("id/enabled"); continue }
            all.append(id)
            if on { enabled.append(id) }
        }
        #expect(enabled == ["duckduckgo", "brave", "mojeek", "startpage", "wikipedia"])
        #expect(all.contains("bing") && !enabled.contains("bing"))
        #expect(!all.contains { $0.contains("google") })
        // Round trip through the manifest encoder (sorted keys) is stable.
        let a = try Manifest.encoder().encode(section), b = try Manifest.encoder().encode(try JSONDecoder().decode([JSONValue].self, from: a))
        #expect(a == b)
    }

    @Test func absentFileMeansNoSection() throws {
        #expect(try Build.searchEngines(URL(fileURLWithPath: "/nonexistent/search-engines.yaml")) == nil)
        #expect(try Build.searchEngines(nil) == nil)
    }

    @Test func googleEntryIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "se-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appending(path: "search-engines.yaml")
        try "engines:\n  - {id: google, name: Google, enabled: true}\n".write(to: f, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try Build.searchEngines(f) }
    }
}
