// M6.T16 step 2 (D-026): catalog/runtimes.yaml → the signed catalog's `runtimes[]`. The committed yaml parses and
// lints clean; bad entries (sha, url, tiers, signature mode, duplicate name) fail lint; a catalog without
// runtimes stays byte-identical (the key is omitted, not emitted empty).
@testable import catalog_tool
import Foundation
import Testing

@Suite struct CatalogRuntimesTests {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func entry(_ name: String = "filetools-runtime") -> RuntimeEntry {
        RuntimeEntry(name: name, version: "0.1.0", sha256: String(repeating: "c", count: 64), size_bytes: 73_000_000,
                     url: "http://localhost:4321/runtimes/\(name)-0.1.0.zip", min_app_version: "0.0.1",
                     tiers: ["T0", "T1", "T2", "T3", "T4"], signature_mode: "adhoc")
    }

    @Test func committedYamlParsesAndLintsClean() throws {
        let list = try #require(try Spec.runtimes(Self.repoRoot.appending(path: "catalog/runtimes.yaml")))
        let ft = try #require(list.first { $0.name == "filetools-runtime" })
        #expect(ft.version.split(separator: ".").count == 3)
        #expect(Lint.runtimeErrors(list) == [])
    }

    @Test func badEntriesFailLint() {
        var e = Self.entry()
        e.sha256 = "xyz"; e.url = "ftp://x/y.tar"; e.tiers = ["T9"]; e.signature_mode = "none"; e.size_bytes = 0; e.version = "1.0"
        let errors = Lint.runtimeErrors([e])
        for needle in ["sha256", "url must be http", "url must name a .zip", "tiers", "signature_mode", "size_bytes", "version"] {
            #expect(errors.contains { $0.contains(needle) }, "\(needle) in \(errors)")
        }
    }

    @Test func duplicateNameIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rt-yaml-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let y = """
        runtimes:
          - {name: a-runtime, version: "1.0.0", sha256: \(String(repeating: "a", count: 64)), size_bytes: 1, url: "http://h/a.zip", min_app_version: "0.0.1", tiers: [T0], signature_mode: adhoc}
          - {name: a-runtime, version: "1.0.1", sha256: \(String(repeating: "b", count: 64)), size_bytes: 1, url: "http://h/b.zip", min_app_version: "0.0.1", tiers: [T0], signature_mode: adhoc}
        """
        try Data(y.utf8).write(to: dir.appending(path: "runtimes.yaml"))
        #expect(throws: ToolError.self) { try Spec.runtimes(dir.appending(path: "runtimes.yaml")) }
        #expect(try Spec.runtimes(dir.appending(path: "missing.yaml")) == nil)
    }

    @Test func runtimesAreOmittedWhenAbsentAndEmittedWhenPresent() throws {
        var m = LintFixture.manifest(LintFixture.valid)
        #expect(!String(decoding: try m.encoded(), as: UTF8.self).contains("\"runtimes\""))
        m.runtimes = [Self.entry()]
        let json = String(decoding: try m.encoded(), as: UTF8.self)
        #expect(json.contains("\"runtimes\"") && json.contains("\"signature_mode\" : \"adhoc\""))
        #expect(m.content != LintFixture.manifest(LintFixture.valid).content, "adding a runtime changes the content → version + 1")
    }
}
