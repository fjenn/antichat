// `read_skill_file` (M7.T13 step 4; R-262): one text file of a skill's `references/` or `assets/` (≤ 20K characters),
// read on demand after `load_skill`, as its instructions point to it. Read-only, offline, contained in the skill folder.
import AntiChatFoundation
import Foundation

public enum ReadSkillFileTool {
    public static let name = "read_skill_file"
    public static let description = "Read one text file of a loaded skill (under references/ or assets/), as the skill's instructions point to it."
    public static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string","description":"The skill name"},"path":{"type":"string","description":"A path inside the skill, e.g. references/style.md"}},"required":["name","path"]}"#
    public static let maxCharacters = 20_000

    struct Args: Decodable { var name: String; var path: String }

    /// The requested path, trimmed of slashes (nil = malformed).
    public static func path(_ argumentsJSON: String) -> String? {
        (try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8)))?.path
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case malformed, noSkill(String), outside(String), notFound(String), notText(String)
        public var description: String {
            switch self {
            case .malformed: "read_skill_file needs {\"name\": …, \"path\": \"references/…\"}."
            case .noSkill(let n): "No skill named \(n) is installed and on."
            case .outside(let p): "\(p) is not under references/ or assets/ of the skill."
            case .notFound(let p): "The skill has no file \(p)."
            case .notText(let p): "\(p) is not a text file."
            }
        }
    }

    /// Reads `path` of skill `name` from `store`: only `references/` and `assets/`, no `..`, no symlink out, UTF-8 text,
    /// cut to 20K characters with a notice.
    public static func read(_ argumentsJSON: String, store: SkillStore, allowed: (String) -> Bool = { _ in true }) throws -> String {
        guard let a = try? JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8)) else { throw ReadError.malformed }
        guard allowed(a.name), let skill = store.skill(named: a.name), skill.isValid else { throw ReadError.noSkill(a.name) }
        let rel = a.path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = rel.split(separator: "/").map(String.init)
        guard let top = parts.first, ["references", "assets"].contains(top), parts.count >= 2,
              !parts.contains(".."), !parts.contains(".") else { throw ReadError.outside(a.path) }
        let dir = store.directory(for: skill.record.path)
        let url = dir.appendingPathComponent(rel)
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(dir.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw ReadError.outside(a.path) }
        guard let data = FileManager.default.contents(atPath: resolved) else { throw ReadError.notFound(rel) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ReadError.notText(rel) }
        // M7.T16 review #7: third-party skill text is untrusted context, wrapped like a skill body.
        guard text.count > maxCharacters else { return UntrustedText.skillFile(skill: skill.name, path: rel, body: text) }
        return UntrustedText.skillFile(skill: skill.name, path: rel, body: String(text.prefix(maxCharacters)))
            + "\n[File shortened: the first \(maxCharacters) characters are shown.]"
    }
}
