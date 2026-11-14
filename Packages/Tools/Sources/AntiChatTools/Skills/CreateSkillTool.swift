// `create_skill` (M7.T13 step 5; R-264 AC1): the user asks for a skill in chat ("Build me a skill that turns my notes into
// a weekly status email"); the model calls `create_skill {name, description, body, references?}`. The arguments are
// rendered to a SKILL.md and checked with `SkillValidator` before the call runs (a finding = a malformed call: one
// repair turn, RepairRetry). The call itself installs nothing: the reply shows a SkillInstallCard with the generated
// SKILL.md and [Install]; only the user's press installs it (`install`), enabled for that chat and offered from the next
// turn. A created skill is instructions only: no `scripts/` (R-265), no network.
import AntiChatStorage
import Foundation
import OsaurusVendored

public enum CreateSkillTool {
    public static let name = "create_skill"
    public static let description = "Create a new skill (reusable instructions for a kind of task). Call this whenever the user asks to build, create, make or save a skill, instead of writing the skill in your reply; the user then reviews the SKILL.md and installs it."
    public static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","description":"lowercase-hyphenated name, 1-64 characters of a-z, 0-9 and -, e.g. weekly-status-email"},"description":{"type":"string","description":"One or two sentences: what the skill does and when to use it (max 1024 characters)"},"body":{"type":"string","description":"The skill's instructions in Markdown: steps, format, an example"},"references":{"type":"array","description":"Optional extra text files","items":{"type":"object","properties":{"path":{"type":"string","description":"e.g. references/example.md"},"content":{"type":"string"}},"required":["path","content"]}}},"required":["name","description","body"]}"#
    public static let maxReferences = 5
    public static let maxReferenceCharacters = 20_000

    public struct Reference: Codable, Sendable, Hashable { public var path: String; public var content: String }

    public struct Draft: Codable, Sendable, Hashable {
        public var name: String
        public var description: String
        public var body: String
        public var references: [Reference]?

        /// The SKILL.md text: YAML frontmatter (name, description as a quoted string) + the body.
        public var markdown: String {
            let desc = (try? JSONEncoder().encode(description.trimmingCharacters(in: .whitespacesAndNewlines)))
                .map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
            return "---\nname: \(name.trimmingCharacters(in: .whitespacesAndNewlines))\ndescription: \(desc)\n---\n\n"
                + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
    }

    /// The draft of a call (nil = not the expected object). Tolerates `references` as a {path: content} object.
    public static func draft(_ argumentsJSON: String) -> Draft? {
        let data = Data(argumentsJSON.utf8)
        if let d = try? JSONDecoder().decode(Draft.self, from: data) { return d }
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let map = obj["references"] as? [String: String] {
            obj["references"] = map.sorted { $0.key < $1.key }.map { ["path": $0.key, "content": $0.value] }
        }
        guard let fixed = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return try? JSONDecoder().decode(Draft.self, from: fixed)
    }

    /// Everything wrong with a call, in the validator's words (empty = installable). `existing` = installed names.
    public static func problems(_ argumentsJSON: String, existing: Set<String> = []) -> [String] {
        guard let d = draft(argumentsJSON) else { return ["create_skill needs {\"name\", \"description\", \"body\"} as strings."] }
        var out: [String] = []
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if existing.contains(name) { out.append("A skill named '\(name)' is already installed; choose another name.") }
        if d.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("The skill body (instructions) is empty.") }
        do {
            let doc = try SkillDocument(markdown: d.markdown)
            out += SkillValidator.validate(doc, directoryName: name).filter(\.blocking).map(\.message)
        } catch {
            out.append("\(error)")
        }
        let refs = d.references ?? []
        if refs.count > maxReferences { out.append("At most \(maxReferences) reference files.") }
        for r in refs {
            if referencePath(r.path) == nil { out.append("Reference path '\(r.path)' must be references/<file>.md or .txt.") }
            if r.content.count > maxReferenceCharacters { out.append("Reference '\(r.path)' is over \(maxReferenceCharacters) characters.") }
        }
        return out
    }

    /// `references/<one safe file name>.md|.txt`, or nil.
    static func referencePath(_ p: String) -> String? {
        let parts = p.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "references", let file = parts.last, !file.hasPrefix("."),
              file.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,80}\.(md|txt)$"#, options: .regularExpression) != nil else { return nil }
        return parts.joined(separator: "/")
    }

    /// The model's result after a valid call (the card does the rest).
    public static func result(_ d: Draft) -> String {
        "The skill '\(d.name)' is ready for review: the user sees its SKILL.md with an Install button. It is not installed yet. Tell the user in one short sentence; do not repeat the SKILL.md."
    }

    /// Writes the draft to a staging folder and installs it through the importer (validation, limits, staged swap).
    /// Never replaces an installed skill of the same name, nor a folder of that name in Skills that has no row yet (one
    /// dropped in through Finder before the next reconcile; M9 review T9): that fails with "A skill named … already
    /// exists", and the folder is left as it is.
    @discardableResult
    public static func install(_ d: Draft, into store: SkillStore) throws -> InstalledSkill {
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        let taken = [name, SkillImporter.safeFolderName(name)].contains { fm.fileExists(atPath: store.directory(for: $0).path) }
        if store.skill(named: name) != nil || taken { throw SkillFileError.skillAlreadyExists(name: name) }
        let work = fm.temporaryDirectory.appendingPathComponent("antichat-create-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let dir = work.appendingPathComponent(SkillImporter.safeFolderName(name), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try d.markdown.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        for r in d.references ?? [] {
            guard let rel = referencePath(r.path) else { continue }
            let url = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try r.content.write(to: url, atomically: true, encoding: .utf8)
        }
        let candidate = try SkillImporter.inspect(dir)
        guard candidate.canInstall else { throw SkillFileError.invalidSkillArchive }
        defer { candidate.discard() }
        // `replacing: false`: a folder that appeared since the check above is never moved aside (or its backup deleted).
        return try store.install(from: candidate.stagedRoot, name: candidate.name, trust: .user, replacing: false)
    }
}
