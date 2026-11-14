// M7.T12 (R-082 AC1, R-261 AC2; AT-261 c2 `make test-unit FILTER=ExportRoundTripTests` then
// `tools/ci/skills-ref-validate.sh build/at/AT-261/exports/*`): every imported example and every starter exports to a
// zip with one top-level `<name>/` folder that re-imports unchanged; the zips are kept in build/at/AT-261/exports/
// for the reference validator.
import AntiChatStorage
import Foundation
import Testing
import ZIPFoundation
@testable import AntiChatTools

@Suite struct ExportRoundTripTests {
    static var exportsDir: URL { SkillFixtures.repoRoot.appendingPathComponent("build/at/AT-261/exports", isDirectory: true) }

    @Test func examplesAndStartersExportAndReimportUnchanged() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        for folder in try SkillFixtures.exampleFolders() {
            try SkillImporter.install(try SkillImporter.inspect(folder), into: t.store)
        }
        try StarterSkills.installIfNeeded(into: t.store)
        let out = Self.exportsDir
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let back = try TempSkillStore()
        defer { back.cleanup() }
        var log: [String] = []
        for s in t.store.list() {
            let zip = out.appendingPathComponent("\(s.name).zip")
            let warnings = try SkillExporter.export(s.name, from: t.store, to: zip)
            #expect(warnings.isEmpty, "\(s.name): \(warnings)")
            let archive = try Archive(url: zip, accessMode: .read)
            #expect(archive.allSatisfy { $0.path.hasPrefix("\(s.name)/") }, "one top-level folder named after the skill")
            let c = try SkillImporter.inspect(zip)
            #expect(c.issues.isEmpty, "\(s.name): \(c.issues)")
            let again = try SkillImporter.install(c, into: back.store)
            #expect(SkillFixtures.sameTree(t.store.directory(for: s.name), back.store.directory(for: again.name)), "\(s.name) round trip")
            log.append("\(s.name).zip\tentries=\(archive.reduce(0) { n, _ in n + 1 })\treimport=unchanged")
        }
        #expect(log.count == t.store.list().count)
        ImportTests.writeLog("AT-261", name: "c2-exports.tsv", lines: log)
    }

    /// Keys outside the spec's set are kept on import and moved under `metadata` on export, so the zip validates.
    @Test func unknownTopLevelKeysMoveUnderMetadataOnExport() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let dir = t.dir.appendingPathComponent("src/legacy-skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: legacy-skill\ndescription: Old style.\nversion: 1.2.0\nauthor: Someone\n---\n\n# Legacy\n\nBody text.\n"
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let c = try SkillImporter.inspect(dir)
        #expect(c.canInstall && c.issues.count == 1 && c.issues[0].kind == .unexpectedFields)
        try SkillImporter.install(c, into: t.store)
        let zip = t.dir.appendingPathComponent("legacy-skill.zip")
        let warnings = try SkillExporter.export("legacy-skill", from: t.store, to: zip)
        #expect(warnings.map(\.kind) == [.unexpectedFields])
        let re = try SkillImporter.inspect(zip)
        defer { re.discard() }
        #expect(re.issues.isEmpty, "\(re.issues)")
        #expect(re.document?.frontmatter["metadata"] == .mapping(["version": .string("1.2.0"), "author": .string("Someone")]))
        #expect(re.document?.body == "# Legacy\n\nBody text.")
    }

    @Test func invalidSkillDoesNotExport() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let dir = t.store.directory(for: "broken")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: Broken\ndescription: d\n---\nx".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try t.store.reconcile()
        let s = try #require(t.store.skill(named: "broken"))
        #expect(!s.isValid)
        #expect(throws: SkillExporter.ExportError.self) {
            try SkillExporter.export("broken", from: t.store, to: t.dir.appendingPathComponent("broken.zip"))
        }
    }
}
