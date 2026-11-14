// M8.T07 step 1 (R-093; P-platform-10): the AntiChat export-all zip, format v1 (documented in FORMAT.md next to this
// file). Rows travel as JSON objects keyed by column name (every column of the row as stored, BLOB columns dropped),
// so a re-import into the same or a later schema restores them verbatim (same ids, same timestamps) and a column
// added by a later migration only needs its default.
import Foundation
import GRDB

public enum AntiChatExportFormat {
    public static let formatID = "antichat-export"
    public static let version = 1

    public static let manifestPath = "manifest.json"
    public static let blobsPath = "media/blobs.json"
    public static let memoryPath = "memory/memory.json"
    public static let settingsPath = "settings/defaults.json"

    public static func chatPath(_ id: String) -> String { "chats/\(id).json" }
    public static func projectPath(_ id: String) -> String { "projects/\(id)/project.json" }
    public static func mediaPath(sha256: String, ext: String) -> String { "media/\(sha256)\(ext.isEmpty ? "" : "." + ext)" }

    /// `AntiChat-Export-<yyyy-MM-dd-HHmm>.zip` (local time).
    public static func fileName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "AntiChat-Export-\(f.string(from: now)).zip"
    }

    /// A file-name-safe slug of a title (lowercase ASCII words joined by `-`, ≤ 48 characters; "chat" when empty).
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX"))
        var out = ""
        var dash = false
        for u in folded.unicodeScalars {
            if u.isASCII, CharacterSet.alphanumerics.contains(u) {
                out.unicodeScalars.append(u); dash = false
            } else if !dash, !out.isEmpty {
                out.append("-"); dash = true
            }
            if out.count >= 48 { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "chat" : out
    }

    public struct Counts: Codable, Sendable, Equatable {
        public var chats = 0, messages = 0, projects = 0, memories = 0, media = 0
        public init() {}
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public var format: String
        public var version: Int
        public var appVersion: String
        public var schemaVersion: String
        public var createdAt: Date
        public var counts: Counts
        public var includesMedia: Bool
        public var includesSettings: Bool

        enum CodingKeys: String, CodingKey {
            case format, version, counts
            case appVersion = "app_version", schemaVersion = "schema_version", createdAt = "created_at"
            case includesMedia = "includes_media", includesSettings = "includes_settings"
        }

        public init(appVersion: String, schemaVersion: String, createdAt: Date, counts: Counts, includesMedia: Bool, includesSettings: Bool) {
            format = AntiChatExportFormat.formatID; version = AntiChatExportFormat.version
            self.appVersion = appVersion; self.schemaVersion = schemaVersion; self.createdAt = createdAt
            self.counts = counts; self.includesMedia = includesMedia; self.includesSettings = includesSettings
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try c.decode(String.self, forKey: .format)
            version = try c.decode(Int.self, forKey: .version)
            appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
            schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? ""
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
            counts = try c.decodeIfPresent(Counts.self, forKey: .counts) ?? Counts()
            includesMedia = try c.decodeIfPresent(Bool.self, forKey: .includesMedia) ?? false
            includesSettings = try c.decodeIfPresent(Bool.self, forKey: .includesSettings) ?? false
        }

        static let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            e.dateEncodingStrategy = .iso8601
            return e
        }()

        static let decoder: JSONDecoder = {
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return d
        }()
    }

    // MARK: Rows ↔ JSON

    /// Every column of `row` (BLOB values dropped: bookmarks and embeddings are machine-specific).
    static func object(_ row: Row) -> [String: Any] {
        var out: [String: Any] = [:]
        for (col, dbValue) in row {
            switch dbValue.storage {
            case .null: out[col] = NSNull()
            case .int64(let v): out[col] = v
            case .double(let v): out[col] = v
            case .string(let v): out[col] = v
            case .blob: out[col] = NSNull()
            }
        }
        return out
    }

    static func rows(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws -> [[String: Any]] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map(object)
    }

    /// A JSON value back to a database value (integers stay integers, everything else as decoded).
    static func databaseValue(_ v: Any) -> DatabaseValue {
        switch v {
        case is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue.databaseValue }
            let t = String(cString: n.objCType)
            if t == "d" || t == "f" { return n.doubleValue.databaseValue }
            return n.int64Value.databaseValue
        case let s as String: return s.databaseValue
        default: return .null
        }
    }

    /// `INSERT OR IGNORE INTO table (…)` of the object's keys that are columns of `table` here (unknown keys from a
    /// newer export are dropped; columns the export lacks take their defaults). `override` replaces values.
    @discardableResult
    static func insert(_ object: [String: Any], into table: String, columns: Set<String>, db: Database,
                       override: [String: DatabaseValueConvertible?] = [:], orIgnore: Bool = true) throws -> Bool {
        var names: [String] = []
        var values: [DatabaseValue] = []
        for (k, v) in object where columns.contains(k) && override[k] == nil {
            names.append(k); values.append(databaseValue(v))
        }
        for (k, v) in override where columns.contains(k) {
            names.append(k); values.append(v?.databaseValue ?? .null)
        }
        guard !names.isEmpty else { return false }
        let quoted = names.map { "\"\($0)\"" }.joined(separator: ", ")
        let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
        try db.execute(sql: "INSERT \(orIgnore ? "OR IGNORE " : "")INTO \(table) (\(quoted)) VALUES (\(marks))",
                       arguments: StatementArguments(values))
        return db.changesCount > 0
    }

    static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// `settings/defaults.json` (M8.T07 step 1): the app's own preference keys, minus secrets, bookmarks, consent and
/// machine state (window frames, Apple/NS keys), and only JSON-safe values (strings, numbers, booleans, arrays and
/// dictionaries of those). Keychain items are never read. Restore applies the same filter again.
public enum ExportSettings {
    static let blockedFragments = ["bookmark", "token", "secret", "password", "apikey", "api_key", "keychain", "credential",
                                   "installid", "install_id", "relay", "consent", "nswindow", "frame", "splitview"]
    static let blockedPrefixes = ["NS", "Apple", "com.apple.", "AK", "WebKit", "MS", "SU", "_"]

    public static func isExportable(_ key: String) -> Bool {
        let lower = key.lowercased()
        if blockedPrefixes.contains(where: { key.hasPrefix($0) }) { return false }
        return !blockedFragments.contains(where: { lower.contains($0) })
    }

    static func jsonSafe(_ v: Any) -> Bool {
        switch v {
        case is String, is NSNumber: return true
        case let a as [Any]: return a.allSatisfy(jsonSafe)
        case let d as [String: Any]: return d.values.allSatisfy(jsonSafe)
        default: return false
        }
    }

    public static func filtered(_ domain: [String: Any]) -> [String: Any] {
        domain.filter { isExportable($0.key) && jsonSafe($0.value) }
    }

    public static func json(_ domain: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: filtered(domain), options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
    }

    /// Writes the exported keys into `defaults`; returns how many were restored.
    @discardableResult
    public static func restore(_ json: Data, into defaults: UserDefaults) -> Int {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return 0 }
        let keep = filtered(o)
        for (k, v) in keep { defaults.set(v, forKey: k) }
        return keep.count
    }
}
