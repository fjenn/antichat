// M7.T12 step 3 (R-082 AC1, R-261 AC2): Export a skill as a zip whose single top-level folder is the skill
// (`<name>/SKILL.md`, …), the layout the reference validator and other Agent Skills apps read. The folder is zipped as
// installed (byte-identical SKILL.md) after `SkillValidator` passes; a blocking error stops the export. When the
// frontmatter carries keys outside the spec's allowed set (kept on import), the exported SKILL.md moves them under
// `metadata` (string values) so the zip validates (AT-261 c2); nothing else is rewritten.
import Foundation
import OsaurusVendored
import Yams
import ZIPFoundation

public enum SkillExporter {
    public enum ExportError: Error, Equatable, CustomStringConvertible {
        case notInstalled(String), invalid(String)
        public var description: String {
            switch self {
            case .notInstalled(let n): "No skill named \(n)"
            case .invalid(let reason): reason
            }
        }
    }

    /// Writes `<name>.zip` content to `zipURL` (replaced if present). Returns the non-blocking findings (warnings).
    @discardableResult
    public static func export(_ name: String, from store: SkillStore, to zipURL: URL) throws -> [SkillIssue] {
        guard let skill = store.skill(named: name) else { throw ExportError.notInstalled(name) }
        if let reason = skill.invalidReason { throw ExportError.invalid(reason) }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("antichat-skill-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let folder = work.appendingPathComponent(name, isDirectory: true)
        try SkillStore.copyTree(from: store.directory(for: skill.record.path), to: folder)
        let warnings = skill.issues.filter { !$0.blocking }
        if let doc = skill.document, warnings.contains(where: { $0.kind == .unexpectedFields }),
           let md = SkillValidator.skillMarkdown(in: folder) {
            try normalized(doc).write(to: md, atomically: true, encoding: .utf8)
        }
        let after = SkillValidator.validate(directory: folder)
        if let blocking = after.first(where: \.blocking) { throw ExportError.invalid(blocking.message) }
        if fm.fileExists(atPath: zipURL.path) { try fm.removeItem(at: zipURL) }
        try fm.zipItem(at: folder, to: zipURL, shouldKeepParent: true, compressionMethod: .deflate)
        return warnings
    }

    /// The SKILL.md with unknown top-level keys moved under `metadata` (strings), the body unchanged.
    static func normalized(_ doc: SkillDocument) -> String {
        var top: [String: Any] = [:]
        var metadata: [String: String] = [:]
        if case .mapping(let m)? = doc.frontmatter["metadata"] { for (k, v) in m { metadata[k] = v.string ?? SkillDocument.flat(v) } }
        for (k, v) in doc.frontmatter where k != "metadata" {
            if SkillValidator.allowedFields.contains(k) { top[k] = v.json } else { metadata[k] = v.string ?? SkillDocument.flat(v) }
        }
        if !metadata.isEmpty { top["metadata"] = metadata }
        let yaml = (try? Yams.dump(object: top, sortKeys: true)) ?? ""
        return "---\n\(yaml)---\n\n\(doc.body)\n"
    }
}
