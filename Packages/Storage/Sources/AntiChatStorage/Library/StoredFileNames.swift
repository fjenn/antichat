// The name people see for a generated picture or clip. The media store keeps bytes as `<sha256>.<ext>`; the name is
// made from the prompt when the file is saved ("Cosy reading nook.png", then "Cosy reading nook 2.png" in the same
// chat), kept as the artifact's title and in the version's spec (`filename`), and read back here for every place a
// file is shown, saved, shared, dragged or opened.
import Foundation
import GRDB

public enum StoredFileNames {
    /// The app's on-disk database (set at launch): the lookup for views that only know a stored file's path.
    nonisolated(unsafe) public static var database: AppDatabase?

    static let genericTitles: Set<String> = ["image.png", "video.mp4"]
    static let dangling: Set<String> = ["a", "an", "the", "at", "of", "in", "on", "with", "and", "or", "to", "for", "by", "from", "into", "over", "under"]

    /// "a red fox in a snowy forest, golden hour" → "A red fox in a snowy forest": the prompt up to its first
    /// punctuation, whole words, at most 40 characters, safe as a file name; "" when nothing usable is left.
    public static func base(prompt: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -'"))
        let head = prompt.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: allowed.inverted)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var words: [Substring] = [], length = 0
        for w in head.split(separator: " ") {
            guard length + w.count + 1 <= 40 else { break }
            words.append(w)
            length += w.count + 1
        }
        // A name cut at the length limit does not end on a joining word ("A small sailboat on a calm lake at").
        while words.count > 1, let last = words.last, dangling.contains(last.lowercased()) { words.removeLast() }
        let name = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -'"))
        return name.isEmpty ? "" : name.prefix(1).uppercased() + name.dropFirst()
    }

    /// `base` + "." + `ext`, with " 2", " 3" … before the extension until no name in `taken` (case-insensitive) matches.
    public static func unique(base: String, ext: String, taken: Set<String>) -> String {
        let lower = Set(taken.map { $0.lowercased() })
        var name = "\(base).\(ext)", n = 2
        while lower.contains(name.lowercased()) {
            name = "\(base) \(n).\(ext)"
            n += 1
        }
        return name
    }

    /// Every media name already used in chat `chatID` (artifact titles and version names).
    public static func taken(chatID: String, _ db: Database) throws -> Set<String> {
        var out = Set<String>()
        for r in try Row.fetchAll(db, sql: """
            SELECT a.title AS title, v.spec_json AS spec FROM artifact a
            LEFT JOIN artifact_version v ON v.artifact_id = a.id WHERE a.chat_id = ?
            """, arguments: [chatID]) {
            out.insert(r["title"] as String? ?? "")
            if let n = specName(r["spec"]) { out.insert(n) }
        }
        return out
    }

    /// A new, unused name in chat `chatID` for a file made from `prompt` (`fallback` when the prompt gives none).
    public static func make(prompt: String?, fallback: String, ext: String, chatID: String, database: AppDatabase) -> String {
        let b = prompt.map(base(prompt:)) ?? ""
        let taken = (try? database.read { try taken(chatID: chatID, $0) }) ?? []
        return unique(base: b.isEmpty ? fallback : b, ext: ext, taken: taken)
    }

    static func specName(_ spec: String?) -> String? {
        guard let spec, let o = (try? JSONSerialization.jsonObject(with: Data(spec.utf8))) as? [String: Any],
              let n = o["filename"] as? String, !n.isEmpty else { return nil }
        return n
    }

    /// The name of one stored version: its own name, else the artifact's title — and for a file saved before names
    /// existed ("image.png" / "video.mp4") a name from its prompt.
    public static func name(title: String, specJSON: String?) -> String {
        if let n = specName(specJSON) { return n }
        guard genericTitles.contains(title.lowercased()), let specJSON,
              let o = (try? JSONSerialization.jsonObject(with: Data(specJSON.utf8))) as? [String: Any],
              let prompt = o["prompt"] as? String else { return title }
        let b = base(prompt: prompt)
        return b.isEmpty ? title : "\(b).\((title as NSString).pathExtension)"
    }

    /// The name of the stored file at `path` (nil = not a file of `database`): the newest version that uses it, else
    /// the attachment's own name.
    public static func name(forPath path: String, database: AppDatabase? = StoredFileNames.database) -> String? {
        guard let database else { return nil }
        return try? database.read { db -> String? in
            if let r = try Row.fetchOne(db, sql: """
                SELECT a.title AS title, v.spec_json AS spec FROM file_blob b
                JOIN artifact_version v ON v.blob_id = b.id JOIN artifact a ON a.id = v.artifact_id
                WHERE b.path = ? ORDER BY v.created_at DESC LIMIT 1
                """, arguments: [path]) {
                return name(title: r["title"] as String? ?? "", specJSON: r["spec"])
            }
            return try String.fetchOne(db, sql: """
                SELECT t.display_name FROM file_blob b JOIN attachment t ON t.blob_id = b.id WHERE b.path = ? LIMIT 1
                """, arguments: [path])
        }
    }
}
