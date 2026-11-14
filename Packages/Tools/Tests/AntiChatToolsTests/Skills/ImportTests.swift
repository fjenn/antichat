// M7.T12 (R-082 AC1/AC5, R-261 AC1; AT-082 `make test-unit FILTER=ImportTests`, AT-261 c1
// `FILTER=ImportTests/testOfficialExamplesImportUnedited`): the four Add forms (folder, .zip, .skill, single SKILL.md)
// stage a candidate with the full SKILL.md text before anything is installed; the official examples import with zero
// edits and zero validation errors; the bad fixtures are refused; the starter skills install once, editable.
import AntiChatStorage
import Foundation
import Testing
import ZIPFoundation
@testable import AntiChatTools

@Suite struct ImportTests {
    /// AT-261 c1: every skill in fixtures/skills/agentskills-examples@<sha>/ imports with zero edits (the installed
    /// folder is byte-identical to the source) and zero validation errors.
    @Test func testOfficialExamplesImportUnedited() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let folders = try SkillFixtures.exampleFolders()
        #expect(folders.count >= 10, "fixtures/skills/agentskills-examples@\(SkillFixtures.examplesSHA) missing (git submodule update + lfs pull)")
        var log: [String] = []
        for folder in folders {
            let c = try SkillImporter.inspect(folder)
            #expect(c.issues.isEmpty, "\(folder.lastPathComponent): \(c.issues)")
            #expect(c.markdown == (try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)),
                    "the review sheet shows the full, unedited SKILL.md")
            let installed = try SkillImporter.install(c, into: t.store)
            #expect(installed.name == folder.lastPathComponent)
            #expect(installed.issues.isEmpty)
            #expect(SkillFixtures.sameTree(folder, t.store.directory(for: installed.name)), "\(installed.name) changed on import")
            log.append("\(installed.name)\tfiles=\(installed.files.count)\tscripts=\(installed.hasScripts)\terrors=\(installed.issues.count)\tunedited=true")
        }
        #expect(t.store.list().count == folders.count)
        Self.writeLog("AT-261", name: "c1-import.tsv", lines: log)
    }

    /// The four Add forms reach the review step with the same candidate (R-082 AC1).
    @Test func folderZipSkillAndMarkdownAllStageForReview() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let src = SkillFixtures.examples.appendingPathComponent("brand-guidelines")
        let zip = t.dir.appendingPathComponent("brand-guidelines.zip")
        try FileManager.default.createDirectory(at: t.dir, withIntermediateDirectories: true)
        try FileManager.default.zipItem(at: src, to: zip, shouldKeepParent: true)
        let skill = t.dir.appendingPathComponent("brand-guidelines.skill")
        try FileManager.default.copyItem(at: zip, to: skill)
        // A zip with SKILL.md at its root: the archive's name is the folder name.
        let flat = t.dir.appendingPathComponent("brand-guidelines-flat/brand-guidelines.zip")
        try FileManager.default.createDirectory(at: flat.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.zipItem(at: src, to: flat, shouldKeepParent: false)
        let mdFile = t.dir.appendingPathComponent("notes.md")
        try FileManager.default.copyItem(at: src.appendingPathComponent("SKILL.md"), to: mdFile)

        let full = try String(contentsOf: src.appendingPathComponent("SKILL.md"), encoding: .utf8)
        for url in [src, zip, skill, flat, mdFile] {
            let c = try SkillImporter.inspect(url)
            #expect(c.name == "brand-guidelines", "\(url.lastPathComponent)")
            #expect(c.canInstall, "\(url.lastPathComponent): \(c.issues)")
            #expect(c.markdown == full, "full text before install (\(url.lastPathComponent))")
            #expect(c.files.contains { $0.relativePath == "SKILL.md" })
            #expect(t.store.list().isEmpty, "nothing is installed before [Install]")
            c.discard()
        }
        let c = try SkillImporter.inspect(zip)
        try SkillImporter.install(c, into: t.store)
        #expect(t.store.list().map(\.name) == ["brand-guidelines"])
        #expect(t.store.list()[0].record.trust == .user)
    }

    /// Review-sheet facts: scripts note, allowed-tools, compatibility.
    @Test func candidateCarriesScriptsAllowedToolsAndCompatibility() throws {
        let c = try SkillImporter.inspect(SkillFixtures.examples.appendingPathComponent("webapp-testing"))
        defer { c.discard() }
        #expect(c.hasScripts, "scripts/ → skills.scripts.note")
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let dir = t.dir.appendingPathComponent("researcher")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: researcher\ndescription: Researches.\ncompatibility: Needs internet access\nallowed-tools: web_search read_url\n---\nDo research."
            .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let r = try SkillImporter.inspect(dir)
        defer { r.discard() }
        #expect(r.compatibility == "Needs internet access")
        #expect(r.allowedTools == ["web_search", "read_url"])
        #expect(!r.hasScripts)
    }

    /// The bad folders are refused (blocking issue or a thrown limit), and nothing lands in the store.
    @Test func badFixturesAreRefused() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let bad = SkillFixtures.bad
        func only(_ sub: String) throws -> URL {
            try #require(try FileManager.default.contentsOfDirectory(at: bad.appendingPathComponent(sub), includingPropertiesForKeys: nil)
                .first { !$0.lastPathComponent.hasPrefix(".") })
        }
        let long = try SkillImporter.inspect(try only("name-too-long"))
        #expect(long.blockingIssue?.message.contains("exceeds 64 character limit") == true)
        let dash = try SkillImporter.inspect(try only("double-hyphen"))
        #expect(dash.blockingIssue?.message == "Skill name cannot contain consecutive hyphens")
        let mismatch = try SkillImporter.inspect(try only("folder-mismatch"))
        #expect(mismatch.blockingIssue?.message == "Directory name 'wrong-folder' must match skill name 'right-name'")
        for c in [long, dash, mismatch] {
            #expect(!c.canInstall)
            #expect(throws: (any Error).self) { try SkillImporter.install(c, into: t.store) }
            c.discard()
        }
        #expect(throws: (any Error).self) { try SkillImporter.inspect(try only("symlink")) }
        #expect(throws: (any Error).self) { try SkillImporter.inspect(bad.appendingPathComponent("too-many-files.zip")) }
        #expect(t.store.list().isEmpty)
    }

    /// R-082 AC5: five starter skills, meeting-notes + email-polish on, none with scripts, installed once as editable
    /// folders (an edit on disk is picked up; a deleted starter does not come back).
    @Test func testStarterSkillsPresentEditable() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let installed = try StarterSkills.installIfNeeded(into: t.store)
        #expect(installed == StarterSkills.names)
        let list = t.store.list()
        #expect((4...6).contains(list.count))
        for s in list {
            #expect(s.isValid, "\(s.name): \(s.issues)")
            #expect(!s.hasScripts)
            #expect(s.record.trust == .bundled)
            #expect(s.record.enabled == StarterSkills.onByDefault.contains(s.name))
            #expect(s.record.applyAll == false)
        }
        // Editable: change the file, reconcile, the row follows.
        let md = t.store.directory(for: "meeting-notes").appendingPathComponent("SKILL.md")
        let edited = try String(contentsOf: md, encoding: .utf8).replacingOccurrences(of: "# Meeting notes", with: "# Meeting notes (mine)")
        try edited.write(to: md, atomically: true, encoding: .utf8)
        let before = try #require(t.store.skill(named: "meeting-notes")).record.contentHash
        try t.store.reconcile()
        #expect(try #require(t.store.skill(named: "meeting-notes")).record.contentHash != before)
        #expect(t.store.body(of: "meeting-notes")?.contains("(mine)") == true)
        try t.store.delete("trip-planner")
        #expect(try StarterSkills.installIfNeeded(into: t.store).isEmpty)
        #expect(t.store.skill(named: "trip-planner") == nil)
    }

    /// Delete removes the folder and the row; the switches persist.
    @Test func deleteAndSwitches() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        try SkillImporter.install(try SkillImporter.inspect(SkillFixtures.examples.appendingPathComponent("internal-comms")), into: t.store)
        try t.store.setApplyAll("internal-comms", true)
        try t.store.setEnabled("internal-comms", false)
        let s = try #require(t.store.skill(named: "internal-comms"))
        #expect(s.record.applyAll && !s.record.enabled)
        try t.store.delete("internal-comms")
        #expect(t.store.skill(named: "internal-comms") == nil)
        #expect(!FileManager.default.fileExists(atPath: t.store.directory(for: "internal-comms").path))
    }

    static func writeLog(_ at: String, name: String, lines: [String]) {
        let dir = SkillFixtures.repoRoot.appendingPathComponent("build/at/\(at)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
