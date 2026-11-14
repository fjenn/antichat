// M7.T13 step 5 (R-264 AC1): create_skill drafts → SkillValidator findings (one repair turn), a valid draft installs
// through the importer (on for the chat by the host), never over an existing skill, and its SKILL.md validates.
// The real-model leg (prompt "Build me a skill that turns my notes into a weekly status email", T1) is
// App/IntegrationTests/CreateSkillTests.swift; this suite is the deterministic core.
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatTools

@Suite struct CreateSkillTests {
    static func args(name: String = "weekly-status-email", description: String = "Turns raw notes into a weekly status email. Use when the user pastes notes and wants the weekly update.",
                     body: String = "# Weekly status email\n\n1. Group notes into Done, Next, Blocked.\n2. Write a short email.\n",
                     refs: String = "") -> String {
        func q(_ s: String) -> String { String(decoding: try! JSONEncoder().encode(s), as: UTF8.self) }
        return #"{"name":\#(q(name)),"description":\#(q(description)),"body":\#(q(body))\#(refs)}"#
    }

    @Test func testValidDraftHasNoProblemsAndRendersFrontmatter() throws {
        let a = Self.args()
        #expect(CreateSkillTool.problems(a).isEmpty)
        let d = try #require(CreateSkillTool.draft(a))
        let doc = try SkillDocument(markdown: d.markdown)
        #expect(doc.name == "weekly-status-email")
        #expect(doc.description?.hasPrefix("Turns raw notes") == true)
        #expect(SkillValidator.validate(doc, directoryName: "weekly-status-email").isEmpty)
    }

    @Test func testBadNamesAndEmptyBodyAreReported() {
        #expect(!CreateSkillTool.problems(Self.args(name: "Weekly Status")).isEmpty)
        #expect(!CreateSkillTool.problems(Self.args(name: "a--b")).isEmpty)
        #expect(!CreateSkillTool.problems(Self.args(name: String(repeating: "a", count: 65))).isEmpty)
        #expect(!CreateSkillTool.problems(Self.args(description: "")).isEmpty)
        #expect(!CreateSkillTool.problems(Self.args(body: "  ")).isEmpty)
        #expect(!CreateSkillTool.problems(#"{"name": 3}"#).isEmpty)
        #expect(CreateSkillTool.problems(Self.args(), existing: ["weekly-status-email"]).contains { $0.contains("already installed") })
        // Description with quotes and colons survives YAML.
        #expect(CreateSkillTool.problems(Self.args(description: #"Use when: the user says "status" — always."#)).isEmpty)
    }

    @Test func testReferencesPathRules() {
        #expect(CreateSkillTool.problems(Self.args(refs: #","references":[{"path":"references/example.md","content":"x"}]"#)).isEmpty)
        #expect(!CreateSkillTool.problems(Self.args(refs: #","references":[{"path":"../evil.md","content":"x"}]"#)).isEmpty)
        #expect(!CreateSkillTool.problems(Self.args(refs: #","references":[{"path":"scripts/run.sh","content":"x"}]"#)).isEmpty)
        // A {path: content} object is tolerated.
        #expect(CreateSkillTool.draft(Self.args(refs: #","references":{"references/a.md":"A"}"#))?.references?.first?.path == "references/a.md")
    }

    @Test func testInstallCreatesValidFolderAndRefusesOverwrite() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let d = try #require(CreateSkillTool.draft(Self.args(refs: #","references":[{"path":"references/example.md","content":"Example."}]"#)))
        let s = try CreateSkillTool.install(d, into: t.store)
        #expect(s.isValid && s.record.trust == .user)
        #expect(s.files.map(\.relativePath) == ["SKILL.md", "references/example.md"])
        #expect(SkillValidator.validate(directory: t.store.directory(for: s.name)).filter(\.blocking).isEmpty)
        #expect(!s.hasScripts)
        #expect(throws: (any Error).self) { try CreateSkillTool.install(d, into: t.store) }
        // Evidence for AT-264: the folder for the reference validator.
        let out = SkillFixtures.repoRoot.appendingPathComponent("build/at/AT-264/created/\(s.name)")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: t.store.directory(for: s.name), to: out)
    }

    /// M9 review T9: a Skills/<name> folder the user dropped in (no row yet, not reconciled) is never replaced: the
    /// install fails with a clear error and the user's files stay as they were, with no backup folder left behind.
    @Test func testInstallNeverReplacesAnUnreconciledUserFolder() throws {
        let t = try TempSkillStore()
        defer { t.cleanup() }
        let mine = t.store.directory(for: "weekly-status-email")
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let original = "---\nname: weekly-status-email\ndescription: \"My own version.\"\n---\n\nMine.\n"
        try original.write(to: mine.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "keep".write(to: mine.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        #expect(t.store.skill(named: "weekly-status-email") == nil, "no row yet")

        let d = try #require(CreateSkillTool.draft(Self.args()))
        #expect {
            try CreateSkillTool.install(d, into: t.store)
        } throws: { error in
            "\((error as? LocalizedError)?.errorDescription ?? "\(error)")".contains("already exists")
        }
        #expect(try String(contentsOf: mine.appendingPathComponent("SKILL.md"), encoding: .utf8) == original)
        #expect(try String(contentsOf: mine.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep")
        let left = try FileManager.default.contentsOfDirectory(atPath: t.store.root.path)
        #expect(left == ["weekly-status-email"], "\(left)")
        #expect(t.store.skill(named: "weekly-status-email") == nil)

        // The store-level guard: with replacing: false an existing folder is never moved aside.
        let staged = t.dir.appendingPathComponent("staged/weekly-status-email", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try d.markdown.write(to: staged.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try t.store.install(from: staged, name: "weekly-status-email", trust: .user, replacing: false)
        }
        #expect(try String(contentsOf: mine.appendingPathComponent("SKILL.md"), encoding: .utf8) == original)
    }
}
