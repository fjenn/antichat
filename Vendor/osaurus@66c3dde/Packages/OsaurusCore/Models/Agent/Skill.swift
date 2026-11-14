//
//  Skill.swift
//  osaurus
//
//  Defines a Skill - markdown instructions that guide AI behavior.
//  Skills are stored as directories with SKILL.md files following the Agent Skills spec.
//  See: https://agentskills.io/specification
//

import Foundation
// ANTICHAT-PATCH: UP-OS-041 frontmatter is parsed by Yams (the hand-rolled parser is gone)
import Yams
// ANTICHAT-PATCH-END

/// Represents a file within a skill's references or assets directory
public struct SkillFile: Codable, Identifiable, Sendable, Equatable {
    public var id: String { name }
    public let name: String
    public let relativePath: String
    public let size: Int64

    public init(name: String, relativePath: String, size: Int64 = 0) {
        self.name = name
        self.relativePath = relativePath
        self.size = size
    }
}

/// A skill containing instructions/guidance for the AI
/// Follows the Agent Skills specification: https://agentskills.io/specification
public struct Skill: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var description: String
    public var version: String
    public var author: String?
    public var category: String?
    public var keywords: [String]
    public var instructions: String
    public let isBuiltIn: Bool
    public let createdAt: Date
    public var updatedAt: Date

    // MARK: - Plugin Association

    /// The plugin ID if this skill was installed as part of a plugin
    public var pluginId: String?

    /// Whether this skill was installed from a plugin
    public var isFromPlugin: Bool { pluginId != nil }

    // MARK: - Directory Structure

    /// Files in the references/ directory (loaded into context)
    public var references: [SkillFile]
    /// Files in the assets/ directory (supporting files)
    public var assets: [SkillFile]
    /// The directory name (Agent Skills format: lowercase-with-hyphens)
    public var directoryName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        version: String = "1.0.0",
        author: String? = nil,
        category: String? = nil,
        keywords: [String] = [],
        instructions: String = "",
        isBuiltIn: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        references: [SkillFile] = [],
        assets: [SkillFile] = [],
        directoryName: String? = nil,
        pluginId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.category = category
        self.keywords = keywords
        self.instructions = instructions
        self.isBuiltIn = isBuiltIn
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.references = references
        self.assets = assets
        self.directoryName = directoryName
        self.pluginId = pluginId
    }

    /// Total count of associated files
    public var totalFileCount: Int {
        references.count + assets.count
    }

    /// Whether this skill has any associated files
    public var hasAssociatedFiles: Bool {
        totalFileCount > 0
    }

    // MARK: - Built-in Skills

    /// All built-in skills
    ///
    /// Every preset is grounded in real Osaurus tools (like `render_chart`,
    /// `web_search`, `applescript`) rather than generic persona advice, so
    /// enabling a skill teaches the agent a concrete workflow it could not
    /// otherwise know.
    ///
    /// Names are localized; `directoryName` is the stable English slug so an
    /// agent's skill allow-list (`agents[].skills`) names a built-in the same
    /// way in every language.
    public static var builtInSkills: [Skill] {
        // ANTICHAT-PATCH: UP-OS-042 no Osaurus presets (AntiChat ships its own starter skills as SKILL.md folders)
        []
        // ANTICHAT-PATCH-END
    }
}

// MARK: - YAML Frontmatter Parsing

extension Skill {
    /// Parse a skill from markdown content with YAML frontmatter
    public static func parse(from markdown: String) throws -> Skill {
        let (frontmatter, body) = try extractFrontmatter(from: markdown)

        guard let name = frontmatter["name"] as? String, !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }

        let id: UUID
        if let idString = frontmatter["id"] as? String, let parsedId = UUID(uuidString: idString) {
            id = parsedId
        } else {
            id = UUID()
        }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let createdAt: Date
        if let dateString = frontmatter["createdAt"] as? String,
            let parsed = dateFormatter.date(from: dateString)
        {
            createdAt = parsed
        } else {
            createdAt = Date()
        }

        let updatedAt: Date
        if let dateString = frontmatter["updatedAt"] as? String,
            let parsed = dateFormatter.date(from: dateString)
        {
            updatedAt = parsed
        } else {
            updatedAt = Date()
        }

        let keywords: [String]
        if let raw = frontmatter["keywords"] as? String, !raw.isEmpty {
            keywords = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            keywords = []
        }

        return Skill(
            id: id,
            name: name,
            description: frontmatter["description"] as? String ?? "",
            version: frontmatter["version"] as? String ?? "1.0.0",
            author: frontmatter["author"] as? String,
            category: frontmatter["category"] as? String,
            keywords: keywords,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: createdAt,
            updatedAt: updatedAt,
            pluginId: frontmatter["pluginId"] as? String
        )
    }

    /// Convert skill to markdown with YAML frontmatter
    public func toMarkdown() -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var yaml = "---\n"
        yaml += "id: \"\(id.uuidString)\"\n"
        yaml += "name: \"\(escapeYamlString(name))\"\n"
        yaml += "description: \"\(escapeYamlString(description))\"\n"
        yaml += "version: \"\(version)\"\n"
        if let author = author {
            yaml += "author: \"\(escapeYamlString(author))\"\n"
        }
        if let category = category {
            yaml += "category: \"\(escapeYamlString(category))\"\n"
        }
        if !keywords.isEmpty {
            yaml += "keywords: \"\(keywords.joined(separator: ", "))\"\n"
        }
        if let pluginId = pluginId {
            yaml += "pluginId: \"\(escapeYamlString(pluginId))\"\n"
        }
        yaml += "createdAt: \"\(dateFormatter.string(from: createdAt))\"\n"
        yaml += "updatedAt: \"\(dateFormatter.string(from: updatedAt))\"\n"
        yaml += "---\n\n"
        yaml += instructions

        return yaml
    }

    /// Extract YAML frontmatter and body from markdown
    private static func extractFrontmatter(from markdown: String) throws -> ([String: Any], String) {
        guard let split = Self.splitFrontmatter(markdown) else {
            // Distinguish "no frontmatter at all" from "opened but never closed"
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("---") {
                throw SkillParseError.noFrontmatter
            }
            throw SkillParseError.malformedFrontmatter
        }
        let frontmatter = parseYaml(split.frontmatterLines)
        return (frontmatter, split.body)
    }

    /// Splits a markdown document into its YAML frontmatter lines and body.
    /// Returns nil when no closing `---` is found. Returns an empty
    /// frontmatter when the document does not start with `---`.
    ///
    /// Exposed to other parsers in the module (e.g. the Claude plugin
    /// installer) so frontmatter parsing stays consistent across SKILL.md,
    /// agent and command markdown.
    static func splitFrontmatter(_ markdown: String) -> (frontmatterLines: [String], body: String)? {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else {
            return ([], normalized)
        }
        let lines = trimmed.components(separatedBy: "\n")
        var endIndex: Int?
        for (index, line) in lines.enumerated() where index > 0 {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = index
                break
            }
        }
        guard let end = endIndex else { return nil }
        let frontmatterLines = Array(lines[1 ..< end])
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (frontmatterLines, body)
    }

    /// Run `parseYaml` against an arbitrary YAML block. Public-in-module so
    /// other parsers can reuse the same folded/literal scalar handling.
    static func parseYamlBlock(_ lines: [String]) -> [String: Any] {
        parseYaml(lines)
    }

    // ANTICHAT-PATCH: UP-OS-041 Yams replaces the hand-rolled parser (flat pairs, one nesting level, block scalars).
    // Same value shapes as upstream: scalars are strings except `true`/`false` (Bool); mappings become
    // `[String: Any]`, sequences `[Any]`, block scalars without their final newline. A block Yams cannot parse, or that
    // is not a mapping, reads as empty.
    private static func parseYaml(_ lines: [String]) -> [String: Any] {
        guard let node = try? Yams.compose(yaml: lines.joined(separator: "\n")),
              let mapping = yamlValue(node) as? [String: Any]
        else { return [:] }
        return mapping
    }

    private static func yamlValue(_ node: Node) -> Any {
        switch node {
        case .scalar(let scalar):
            if scalar.style == .plain {
                switch scalar.string.lowercased() {
                case "true": return true
                case "false": return false
                default: break
                }
            }
            if scalar.style == .literal || scalar.style == .folded {  // upstream dropped the block's final newline
                var text = scalar.string
                while text.hasSuffix("\n") { text.removeLast() }
                return text
            }
            return scalar.string
        case .mapping(let mapping):
            var out: [String: Any] = [:]
            for (key, value) in mapping {
                guard let k = key.string else { continue }
                out[k] = yamlValue(value)
            }
            return out
        case .sequence(let sequence):
            return sequence.map { yamlValue($0) }
        case .alias:
            return ""
        }
    }
    // ANTICHAT-PATCH-END

    /// Escape special characters for YAML string
    private func escapeYamlString(_ string: String) -> String {
        return
            string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Errors

public enum SkillParseError: Error, LocalizedError {
    case noFrontmatter
    case malformedFrontmatter
    case missingRequiredField(String)

    public var errorDescription: String? {
        switch self {
        case .noFrontmatter:
            return "Skill file must start with YAML frontmatter (---)"
        case .malformedFrontmatter:
            return "Could not parse YAML frontmatter"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        }
    }
}

// MARK: - Export/Import Support

extension Skill {
    /// Export format for sharing skills
    public struct ExportData: Codable {
        public let version: Int
        public let skill: Skill

        public init(skill: Skill) {
            self.version = 1
            // Create a copy without built-in flag for export
            self.skill = Skill(
                id: UUID(),  // Generate new ID on export
                name: skill.name,
                description: skill.description,
                version: skill.version,
                author: skill.author,
                category: skill.category,
                keywords: skill.keywords,
                instructions: skill.instructions,
                isBuiltIn: false,
                createdAt: Date(),
                updatedAt: Date()
            )
        }
    }

    /// Export this skill to JSON data
    public func exportToJSON() throws -> Data {
        let exportData = ExportData(skill: self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(exportData)
    }

    /// Import a skill from JSON data
    public static func importFromJSON(_ data: Data) throws -> Skill {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exportData = try decoder.decode(ExportData.self, from: data)
        return exportData.skill
    }
}

// MARK: - Agent Skills Format Compatibility
// Compatible with https://agentskills.io/specification

extension Skill {
    /// Convert name to Agent Skills format (lowercase, hyphens)
    public var xplaceholder_agentSkillsNamex: String {
        let sanitized = Self.agentSkillsSlug(for: name)
        return sanitized.isEmpty ? "skill-\(id.uuidString.prefix(8).lowercased())" : sanitized
    }

    /// The Agent Skills slug for an arbitrary name (lowercase, hyphens; may
    /// be empty). Shared by the display-name property above and by slug-based
    /// lookups: slash commands and on-disk directories surface this form
    /// (`code-reviewer`), and models copy it into `capabilities_load` ids, so
    /// both sides of a name comparison must slugify identically.
    public static func agentSkillsSlug(for name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
            .joined()
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Export to Agent Skills SKILL.md format
    /// Compatible with: https://agentskills.io/specification
    public func toAgentSkillsFormat() -> String {
        toAgentSkillsFormatInternal(includeId: false)
    }

    /// Export to Agent Skills format with internal ID for local storage
    public func toAgentSkillsFormatWithId() -> String {
        toAgentSkillsFormatInternal(includeId: true)
    }

    private func toAgentSkillsFormatInternal(includeId: Bool) -> String {
        var yaml = "---\n"
        yaml += "name: \(xplaceholder_agentSkillsNamex)\n"

        // Description is required, truncate to 1024 chars per spec
        let truncatedDesc = String(description.prefix(1024))
        yaml += "description: \(escapeAgentSkillsYaml(truncatedDesc))\n"

        // Metadata section
        yaml += "metadata:\n"
        if includeId {
            yaml += "  osaurus-id: \"\(id.uuidString)\"\n"
        }
        if let pluginId = pluginId {
            yaml += "  osaurus-plugin-id: \"\(pluginId)\"\n"
        }
        if let author = author {
            yaml += "  author: \(escapeAgentSkillsYaml(author))\n"
        }
        yaml += "  version: \"\(version)\"\n"
        if let category = category {
            yaml += "  category: \(escapeAgentSkillsYaml(category))\n"
        }
        if !keywords.isEmpty {
            yaml += "  keywords: \"\(keywords.joined(separator: ", "))\"\n"
        }

        yaml += "---\n\n"
        yaml += instructions

        return yaml
    }

    /// Parse from Agent Skills SKILL.md format
    /// Compatible with: https://agentskills.io/specification
    public static func parseAgentSkillsFormat(from markdown: String) throws -> Skill {
        let (frontmatter, body) = try extractFrontmatter(from: markdown)

        // Agent Skills format requires 'name' field
        guard let name = frontmatter["name"] as? String, !name.isEmpty else {
            throw SkillParseError.missingRequiredField("name")
        }

        // Description is required in Agent Skills format
        let description = frontmatter["description"] as? String ?? ""

        // Extract metadata if present
        var author: String?
        var version = "1.0.0"
        var category: String?
        var keywords: [String] = []
        var osaurusId: UUID?
        var pluginId: String?

        if let metadata = frontmatter["metadata"] as? [String: Any] {
            author = metadata["author"] as? String
            version = metadata["version"] as? String ?? "1.0.0"
            category = metadata["category"] as? String
            if let raw = metadata["keywords"] as? String, !raw.isEmpty {
                keywords = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }

            // Osaurus-specific metadata
            if let idString = metadata["osaurus-id"] as? String {
                osaurusId = UUID(uuidString: idString)
            }
            // Legacy `osaurus-enabled` metadata is intentionally ignored:
            // installed skills are always available.
            pluginId = metadata["osaurus-plugin-id"] as? String
        }

        // Top-level `keywords:` fallback. Osaurus exports keywords under
        // `metadata:`, but skill files in the wild commonly put them at the
        // top level of the frontmatter (the Osaurus legacy format does too).
        // Keywords are the discovery signal `SkillSearchService` indexes, so
        // dropping them on import silently degrades capabilities_discover.
        if keywords.isEmpty, let raw = frontmatter["keywords"] as? String, !raw.isEmpty {
            keywords = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        // Convert Agent Skills name (lowercase-hyphen) to display name (Title Case)
        let displayName =
            name
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")

        return Skill(
            id: osaurusId ?? UUID(),
            name: displayName,
            description: description,
            version: version,
            author: author,
            category: category,
            keywords: keywords,
            instructions: body.trimmingCharacters(in: .whitespacesAndNewlines),
            isBuiltIn: false,
            createdAt: Date(),
            updatedAt: Date(),
            pluginId: pluginId
        )
    }

    /// Check if markdown content is in Agent Skills format
    public static func isAgentSkillsFormat(_ markdown: String) -> Bool {
        guard let (frontmatter, _) = try? extractFrontmatter(from: markdown) else {
            return false
        }
        // Agent Skills format has 'name' but no 'id' field
        let hasName = frontmatter["name"] != nil
        let hasId = frontmatter["id"] != nil
        return hasName && !hasId
    }

    /// Parse from either Osaurus or Agent Skills format (auto-detect)
    public static func parseAnyFormat(from markdown: String) throws -> Skill {
        if isAgentSkillsFormat(markdown) {
            return try parseAgentSkillsFormat(from: markdown)
        } else {
            return try parse(from: markdown)
        }
    }

    /// Escape string for Agent Skills YAML format
    private func escapeAgentSkillsYaml(_ string: String) -> String {
        // If string contains special chars, wrap in quotes
        let needsQuotes =
            string.contains(":") || string.contains("#") || string.contains("\"") || string.contains("'")
            || string.contains("\n") || string.hasPrefix(" ") || string.hasSuffix(" ")

        if needsQuotes {
            let escaped =
                string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        return string
    }
}
