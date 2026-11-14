// M8.T09 step 7 (R-218 AC5): About & Help › System report. Tier, speed class, budget B, loaded models (resident GB),
// the last model-load times, TTFT p50 and tok/s p50 over the last 20 replies (numeric provenance fields only:
// `json_extract` of ttft_ms / tok_per_s, never a message body or title), catalog version + expiry, app/engine
// versions and FileVault status. Copyable text and JSON (the log bundle's `system-report.json`); no chat content.
import AntiChatStorage
import Foundation
import GRDB

public struct SystemReport: Codable, Sendable, Equatable {
    public struct LoadedModel: Codable, Sendable, Equatable {
        public var id: String
        public var residentGB: Double?
        public init(id: String, residentGB: Double?) { self.id = id; self.residentGB = residentGB }
    }

    public var appVersion: String
    public var engineVersion: String?
    public var macOSVersion: String
    public var chip: String
    public var ramGB: Int
    public var tier: String
    public var speedClass: String
    public var budgetGB: Double?
    public var loadedModels: [LoadedModel]
    public var lastLoadTimesMs: [Double]
    public var ttftP50Ms: Double?
    public var tokPerSecP50: Double?
    public var perfSampleCount: Int
    public var catalogVersion: Int?
    public var catalogExpires: String?
    public var fileVault: String

    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version", engineVersion = "engine_version", macOSVersion = "macos_version", chip
        case ramGB = "ram_gb", tier, speedClass = "speed_class", budgetGB = "budget_gb", loadedModels = "loaded_models"
        case lastLoadTimesMs = "last_load_times_ms", ttftP50Ms = "ttft_p50_ms", tokPerSecP50 = "tok_per_s_p50"
        case perfSampleCount = "perf_samples", catalogVersion = "catalog_version", catalogExpires = "catalog_expires"
        case fileVault = "filevault"
    }

    public init(appVersion: String, engineVersion: String? = nil, macOSVersion: String, chip: String, ramGB: Int, tier: String,
                speedClass: String, budgetGB: Double?, loadedModels: [LoadedModel] = [], lastLoadTimesMs: [Double] = [],
                ttftP50Ms: Double? = nil, tokPerSecP50: Double? = nil, perfSampleCount: Int = 0, catalogVersion: Int? = nil,
                catalogExpires: String? = nil, fileVault: String = "unknown") {
        self.appVersion = appVersion; self.engineVersion = engineVersion; self.macOSVersion = macOSVersion; self.chip = chip
        self.ramGB = ramGB; self.tier = tier; self.speedClass = speedClass; self.budgetGB = budgetGB; self.loadedModels = loadedModels
        self.lastLoadTimesMs = lastLoadTimesMs; self.ttftP50Ms = ttftP50Ms; self.tokPerSecP50 = tokPerSecP50
        self.perfSampleCount = perfSampleCount; self.catalogVersion = catalogVersion; self.catalogExpires = catalogExpires
        self.fileVault = fileVault
    }

    /// Builds the report from what this process knows; `database` is read for the numeric perf fields only.
    public static func collect(profile: HardwareProfile?, database: AppDatabase?, catalog: CatalogStore.Snapshot? = nil,
                               loadedModels: [LoadedModel] = [], lastLoadTimesMs: [Double] = [],
                               fileVault: String = fileVaultStatus()) -> SystemReport {
        let ctx = CrashContext.current(profile: profile)
        let perf = (try? database.map(perfP50)) ?? nil
        return SystemReport(
            appVersion: ctx.appVersion, engineVersion: "mlx-swift-lm \(CatalogStore.engineVersions["mlx-swift-lm"] ?? "?") · llama.cpp \(CatalogStore.engineVersions["llama.cpp"] ?? "?")",
            macOSVersion: profile.map { "\($0.osVersion) (\($0.osBuild))" } ?? ctx.macOSVersion,
            chip: profile?.chip ?? "unknown", ramGB: profile?.ramGB ?? 0, tier: profile?.tierKey ?? "unknown",
            speedClass: profile?.speedClass.rawValue ?? "unknown", budgetGB: profile?.B, loadedModels: loadedModels,
            lastLoadTimesMs: Array(lastLoadTimesMs.suffix(5)), ttftP50Ms: perf?.ttft, tokPerSecP50: perf?.tps,
            perfSampleCount: perf?.count ?? 0, catalogVersion: catalog?.catalog?.catalogVersion,
            catalogExpires: catalog?.catalog.map { $0.expires.formatted(.iso8601.year().month().day()) },
            fileVault: fileVault)
    }

    /// The engine's resident set (bytes per model key, from the helper's probe) as report rows, largest first.
    public static func loadedModels(residentBytes: [String: UInt64]) -> [LoadedModel] {
        residentBytes.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { LoadedModel(id: $0.key, residentGB: $0.value > 0 ? Double($0.value) / 1e9 : nil) }
    }

    /// p50 of `ttft_ms` and `tok_per_s` over the last 20 assistant replies that carry them.
    public static func perfP50(_ database: AppDatabase) throws -> (ttft: Double?, tps: Double?, count: Int) {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT json_extract(provenance_json, '$.ttft_ms') AS ttft, json_extract(provenance_json, '$.tok_per_s') AS tps
                FROM message WHERE role = 'assistant' AND provenance_json IS NOT NULL AND json_valid(provenance_json)
                ORDER BY created_at DESC LIMIT 20
                """)
            let ttft = rows.compactMap { $0["ttft"] as Double? }.filter { $0 > 0 }
            let tps = rows.compactMap { $0["tps"] as Double? }.filter { $0 > 0 }
            return (median(ttft), median(tps), rows.count)
        }
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// `fdesetup isactive` (no admin needed): On / Off / unknown.
    public static func fileVaultStatus() -> String { cachedFileVault }

    /// Read once per launch (review fix: never a `fdesetup` wait for every report).
    private static let cachedFileVault: String = readFileVaultStatus()

    static func readFileVaultStatus() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        p.arguments = ["isactive"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "unknown" }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        switch String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return "On"
        case "false": return "Off"
        default: return "unknown"
        }
    }

    public func json() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)) ?? Data("{}".utf8)
    }

    /// The copyable text (one `Label: value` line per field).
    public func text() -> String {
        func gb(_ v: Double?) -> String { v.map { String(format: "%.1f GB", $0) } ?? "—" }
        let models: String = loadedModels.isEmpty ? "none" : loadedModels.map { "\($0.id) (\(gb($0.residentGB)))" }.joined(separator: ", ")
        let loads: String = lastLoadTimesMs.isEmpty ? "—" : lastLoadTimesMs.map { String(format: "%.0f ms", $0) }.joined(separator: ", ")
        let ttft: String = ttftP50Ms.map { String(format: "%.0f ms", $0) } ?? "—"
        let speed: String = tokPerSecP50.map { String(format: "%.1f tokens/s", $0) } ?? "—"
        let catalog: String = (catalogVersion.map { "v\($0)" } ?? "—") + (catalogExpires.map { " · expires \($0)" } ?? "")
        let engine: String = engineVersion.map { " · engine \($0)" } ?? ""
        var lines: [String] = []
        lines.append("AntiChat \(appVersion)\(engine)")
        lines.append("macOS \(macOSVersion)")
        lines.append("Chip: \(chip) · \(ramGB) GB")
        lines.append("Tier: \(tier) · speed class \(speedClass) · budget \(gb(budgetGB))")
        lines.append("Loaded models: \(models)")
        lines.append("Last model loads: \(loads)")
        lines.append("Time to first token (p50, last \(perfSampleCount)): \(ttft)")
        lines.append("Speed (p50): \(speed)")
        lines.append("Catalog: \(catalog)")
        lines.append("FileVault: \(fileVault)")
        lines = lines.map { Redaction.redactSecretLikeSubstrings($0) }
        return lines.joined(separator: "\n")
    }
}
