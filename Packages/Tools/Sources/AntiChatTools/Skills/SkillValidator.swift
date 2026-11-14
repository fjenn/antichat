// Ported from agentskills/agentskills@69ef37e942:skills-ref/src/skills_ref/validator.py and parser.py (Apache-2.0):
// the Agent Skills reference validator, Python → Swift, rule for rule (M7.T12 step 1; R-261; P-files-tools-16).
// Frontmatter: SKILL.md must start with `---`; the text between the first two `---` is the YAML (strictyaml in the
// reference, so every scalar is a string; here Yams, scalars kept as strings); the rest, trimmed, is the body.
// Rules (verbatim): allowed fields name, description, license, allowed-tools, metadata, compatibility; name required,
// NFKC, ≤ 64 characters, lowercase, letters/digits/hyphens, no leading/trailing or double hyphen, equal to the folder
// name; description required, non-empty, ≤ 1024; compatibility a string ≤ 500.
// AntiChat addition: the "Unexpected fields" error is a warning on import (unknown keys are kept; SkillExporter moves
// them under `metadata` so every export validates). Every other error blocks the install.
import Foundation
import Yams

/// One frontmatter value: strictyaml semantics (scalars are strings).
public indirect enum SkillYAML: Sendable, Hashable {
    case string(String)
    case sequence([SkillYAML])
    case mapping([String: SkillYAML])

    public var string: String? { if case .string(let s) = self { s } else { nil } }

    /// JSON-compatible value (manifest_json).
    var json: Any {
        switch self {
        case .string(let s): s
        case .sequence(let a): a.map(\.json)
        case .mapping(let m): m.mapValues(\.json)
        }
    }

    static func from(_ node: Node) -> SkillYAML {
        switch node {
        case .scalar(let s): .string(s.string)
        case .sequence(let seq): .sequence(seq.map(from))
        case .mapping(let map):
            .mapping(Dictionary(map.compactMap { k, v in k.string.map { ($0, from(v)) } }, uniquingKeysWith: { a, _ in a }))
        case .alias: .string("")
        }
    }
}

/// A parsed SKILL.md.
public struct SkillDocument: Sendable, Hashable {
    /// The file text, unedited.
    public let markdown: String
    public let frontmatter: [String: SkillYAML]
    /// The instructions (text after the frontmatter, trimmed).
    public let body: String

    public var name: String? { frontmatter["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var description: String? { frontmatter["description"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var license: String? { frontmatter["license"]?.string }
    public var compatibility: String? { frontmatter["compatibility"]?.string }
    /// `allowed-tools`: space-delimited in the spec (a YAML list is accepted too).
    public var allowedTools: [String] {
        switch frontmatter["allowed-tools"] {
        case .string(let s)?: s.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," }).map(String.init)
        case .sequence(let a)?: a.compactMap(\.string)
        default: []
        }
    }

    /// The frontmatter as sorted-key JSON (`skill.manifest_json`).
    public var manifestJSON: String {
        let obj = frontmatter.mapValues(\.json)
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noFrontmatter, notClosed, invalidYAML(String), notMapping
        public var description: String {
            switch self {
            case .noFrontmatter: "SKILL.md must start with YAML frontmatter (---)"
            case .notClosed: "SKILL.md frontmatter not properly closed with ---"
            case .invalidYAML(let e): "Invalid YAML in frontmatter: \(e)"
            case .notMapping: "SKILL.md frontmatter must be a YAML mapping"
            }
        }
    }

    /// `parse_frontmatter`: `content.split("---", 2)`, YAML of part 1, body = part 2 stripped.
    public init(markdown: String) throws {
        guard markdown.hasPrefix("---") else { throw ParseError.noFrontmatter }
        let afterOpen = markdown.index(markdown.startIndex, offsetBy: 3)
        guard let close = markdown.range(of: "---", range: afterOpen..<markdown.endIndex) else { throw ParseError.notClosed }
        let yaml = String(markdown[afterOpen..<close.lowerBound])
        let node: Node?
        do { node = try Yams.compose(yaml: yaml) } catch { throw ParseError.invalidYAML("\(error)") }
        guard let node, case .mapping = node, case .mapping(var fields) = SkillYAML.from(node) else { throw ParseError.notMapping }
        if case .mapping(let meta)? = fields["metadata"] {  // the reference stringifies metadata values
            fields["metadata"] = .mapping(meta.mapValues { v in v.string.map(SkillYAML.string) ?? .string(Self.flat(v)) })
        }
        self.markdown = markdown
        self.frontmatter = fields
        self.body = String(markdown[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func flat(_ v: SkillYAML) -> String {
        switch v {
        case .string(let s): s
        case .sequence(let a): "[" + a.map(flat).joined(separator: ", ") + "]"
        case .mapping(let m): "{" + m.keys.sorted().map { "\($0): \(flat(m[$0]!))" }.joined(separator: ", ") + "}"
        }
    }
}

/// A validation finding (the reference validator's message, verbatim).
public struct SkillIssue: Sendable, Hashable, CustomStringConvertible {
    public enum Kind: Sendable, Hashable { case unexpectedFields, other }
    public let kind: Kind
    public let message: String
    /// Unknown frontmatter fields are kept (warning); everything else stops the install.
    public var blocking: Bool { kind != .unexpectedFields }
    public var description: String { message }
}

public enum SkillValidator {
    public static let maxNameLength = 64
    public static let maxDescriptionLength = 1024
    public static let maxCompatibilityLength = 500
    public static let allowedFields: Set<String> = ["name", "description", "license", "allowed-tools", "metadata", "compatibility"]

    /// `validate(skill_dir)`: SKILL.md (or skill.md) of `directory`, checked against the directory's name.
    public static func validate(directory: URL) -> [SkillIssue] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir) else {
            return [SkillIssue(kind: .other, message: "Path does not exist: \(directory.path)")]
        }
        guard isDir.boolValue else { return [SkillIssue(kind: .other, message: "Not a directory: \(directory.path)")] }
        guard let md = skillMarkdown(in: directory) else {
            return [SkillIssue(kind: .other, message: "Missing required file: SKILL.md")]
        }
        do {
            let doc = try SkillDocument(markdown: String(contentsOf: md, encoding: .utf8))
            return validate(doc, directoryName: directory.lastPathComponent)
        } catch let e as SkillDocument.ParseError {
            return [SkillIssue(kind: .other, message: e.description)]
        } catch {
            return [SkillIssue(kind: .other, message: "SKILL.md is not readable UTF-8 text")]
        }
    }

    /// `find_skill_md`: SKILL.md, else skill.md.
    public static func skillMarkdown(in directory: URL) -> URL? {
        for n in ["SKILL.md", "skill.md"] {
            let u = directory.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// `validate_metadata(metadata, skill_dir)`.
    public static func validate(_ doc: SkillDocument, directoryName: String?) -> [SkillIssue] {
        var errors: [SkillIssue] = []
        let fm = doc.frontmatter
        let extra = Set(fm.keys).subtracting(allowedFields)
        if !extra.isEmpty {
            let allowed = allowedFields.sorted().map { "'\($0)'" }.joined(separator: ", ")
            errors.append(SkillIssue(kind: .unexpectedFields, message:
                "Unexpected fields in frontmatter: \(extra.sorted().joined(separator: ", ")). Only [\(allowed)] are allowed."))
        }
        if let name = fm["name"] {
            errors += validateName(name, directoryName: directoryName).map { SkillIssue(kind: .other, message: $0) }
        } else {
            errors.append(SkillIssue(kind: .other, message: "Missing required field in frontmatter: name"))
        }
        if let d = fm["description"] {
            errors += validateDescription(d).map { SkillIssue(kind: .other, message: $0) }
        } else {
            errors.append(SkillIssue(kind: .other, message: "Missing required field in frontmatter: description"))
        }
        if let c = fm["compatibility"] {
            errors += validateCompatibility(c).map { SkillIssue(kind: .other, message: $0) }
        }
        return errors
    }

    /// `_validate_name`.
    static func validateName(_ value: SkillYAML, directoryName: String?) -> [String] {
        guard let raw = value.string, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["Field 'name' must be a non-empty string"]
        }
        var errors: [String] = []
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping
        let length = name.unicodeScalars.count  // Python len(): code points
        if length > maxNameLength {
            errors.append("Skill name '\(name)' exceeds \(maxNameLength) character limit (\(length) chars)")
        }
        if name != name.lowercased() { errors.append("Skill name '\(name)' must be lowercase") }
        if name.hasPrefix("-") || name.hasSuffix("-") { errors.append("Skill name cannot start or end with a hyphen") }
        if name.contains("--") { errors.append("Skill name cannot contain consecutive hyphens") }
        if !name.unicodeScalars.allSatisfy({ $0 == "-" || isAlnum($0) }) {
            errors.append("Skill name '\(name)' contains invalid characters. Only letters, digits, and hyphens are allowed.")
        }
        if let directoryName {
            let dir = directoryName.precomposedStringWithCompatibilityMapping
            if dir != name { errors.append("Directory name '\(directoryName)' must match skill name '\(name)'") }
        }
        return errors
    }

    /// Python `str.isalnum` for one code point: a letter (L*) or a numeric character.
    static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: s.properties.numericType != nil
        }
    }

    /// `_validate_description`.
    static func validateDescription(_ value: SkillYAML) -> [String] {
        guard let d = value.string, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["Field 'description' must be a non-empty string"]
        }
        let n = d.unicodeScalars.count
        return n > maxDescriptionLength ? ["Description exceeds \(maxDescriptionLength) character limit (\(n) chars)"] : []
    }

    /// `_validate_compatibility`.
    static func validateCompatibility(_ value: SkillYAML) -> [String] {
        guard let c = value.string else { return ["Field 'compatibility' must be a string"] }
        let n = c.unicodeScalars.count
        return n > maxCompatibilityLength ? ["Compatibility exceeds \(maxCompatibilityLength) character limit (\(n) chars)"] : []
    }
}
