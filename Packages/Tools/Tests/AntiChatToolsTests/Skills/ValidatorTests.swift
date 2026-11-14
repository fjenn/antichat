// M7.T12 step 1 (R-261): SkillValidator = the reference validator's rules (skills-ref validator.py @69ef37e942),
// message for message, plus the frontmatter split of parser.py.
import Foundation
import OsaurusVendored
import Testing
@testable import AntiChatTools

@Suite struct ValidatorTests {
    func issues(_ md: String, dir: String? = "my-skill") throws -> [String] {
        SkillValidator.validate(try SkillDocument(markdown: md), directoryName: dir).map(\.message)
    }

    func md(_ fm: String, body: String = "Body.") -> String { "---\n\(fm)\n---\n\n\(body)\n" }

    @Test func validSkillHasNoIssues() throws {
        #expect(try issues(md("name: my-skill\ndescription: Does a thing."), dir: "my-skill").isEmpty)
    }

    @Test func nameRulesVerbatim() throws {
        #expect(try issues(md("name: My-Skill\ndescription: d"), dir: "My-Skill") == ["Skill name 'My-Skill' must be lowercase"])
        #expect(try issues(md("name: -skill\ndescription: d"), dir: "-skill") == ["Skill name cannot start or end with a hyphen"])
        #expect(try issues(md("name: my--skill\ndescription: d"), dir: "my--skill") == ["Skill name cannot contain consecutive hyphens"])
        #expect(try issues(md("name: my_skill\ndescription: d"), dir: "my_skill")
            == ["Skill name 'my_skill' contains invalid characters. Only letters, digits, and hyphens are allowed."])
        let long = String(repeating: "a", count: 65)
        #expect(try issues(md("name: \(long)\ndescription: d"), dir: long) == ["Skill name '\(long)' exceeds 64 character limit (65 chars)"])
        #expect(try issues(md("name: \(String(repeating: "a", count: 64))\ndescription: d"), dir: String(repeating: "a", count: 64)).isEmpty)
        #expect(try issues(md("name: right-name\ndescription: d"), dir: "wrong-folder")
            == ["Directory name 'wrong-folder' must match skill name 'right-name'"])
        // i18n: Unicode lowercase letters are allowed (the reference uses str.isalnum()).
        #expect(try issues(md("name: café-notes\ndescription: d"), dir: "café-notes").isEmpty)
    }

    @Test func descriptionAndCompatibility() throws {
        #expect(try issues(md("name: my-skill")) == ["Missing required field in frontmatter: description"])
        #expect(try issues(md("name: my-skill\ndescription: \"  \"")) == ["Field 'description' must be a non-empty string"])
        let d = String(repeating: "x", count: 1025)
        #expect(try issues(md("name: my-skill\ndescription: \(d)")) == ["Description exceeds 1024 character limit (1025 chars)"])
        let c = String(repeating: "y", count: 501)
        #expect(try issues(md("name: my-skill\ndescription: d\ncompatibility: \(c)")) == ["Compatibility exceeds 500 character limit (501 chars)"])
        #expect(try issues(md("description: d"), dir: nil) == ["Missing required field in frontmatter: name"])
    }

    @Test func unknownFieldsAreAWarningNotABlocker() throws {
        let doc = try SkillDocument(markdown: md("name: my-skill\ndescription: d\nversion: 2\nauthor: me"))
        let found = SkillValidator.validate(doc, directoryName: "my-skill")
        #expect(found.count == 1)
        #expect(found[0].kind == .unexpectedFields && !found[0].blocking)
        #expect(found[0].message.hasPrefix("Unexpected fields in frontmatter: author, version. Only ["))
    }

    @Test func frontmatterSplitAndParseErrors() throws {
        #expect(throws: SkillDocument.ParseError.noFrontmatter) { try SkillDocument(markdown: "# no frontmatter") }
        #expect(throws: SkillDocument.ParseError.notClosed) { try SkillDocument(markdown: "---\nname: x\n") }
        #expect(throws: SkillDocument.ParseError.notMapping) { try SkillDocument(markdown: "---\n- a\n- b\n---\nbody") }
        let doc = try SkillDocument(markdown: """
            ---
            name: my-skill
            description: >
              Folded text
              on two lines.
            allowed-tools: web_search Read
            metadata:
              version: 1.0
              tags: [a, b]
            ---

              # Title
            """)
        #expect(doc.description == "Folded text on two lines.")
        #expect(doc.allowedTools == ["web_search", "Read"])
        #expect(doc.body == "# Title")
        #expect(doc.frontmatter["metadata"] == .mapping(["version": .string("1.0"), "tags": .string("[a, b]")]))
        #expect(doc.manifestJSON.contains("\"name\":\"my-skill\""))
    }

    @Test func directoryValidationFindsSkillMd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString)/my-skill")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        #expect(SkillValidator.validate(directory: dir).map(\.message) == ["Missing required file: SKILL.md"])
        try md("name: my-skill\ndescription: d").write(to: dir.appendingPathComponent("skill.md"), atomically: true, encoding: .utf8)
        #expect(SkillValidator.validate(directory: dir).isEmpty)
    }

    /// The vendored Osaurus parser now runs on Yams (UP-OS-041): nested metadata and block scalars still parse.
    @Test func vendoredSkillParsesThroughYams() throws {
        let s = try OsaurusSkillProbe.parse("""
            ---
            name: trip-planner
            description: |
              Plans trips.
              Day by day.
            metadata:
              author: AntiChat
              version: "1.0"
            ---
            Body
            """)
        #expect(s.description == "Plans trips.\nDay by day.")
        #expect(s.author == "AntiChat" && s.version == "1.0")
        #expect(s.instructions == "Body")
    }
}

enum OsaurusSkillProbe {
    static func parse(_ md: String) throws -> Skill { try Skill.parseAgentSkillsFormat(from: md) }
}
