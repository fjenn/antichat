// ⌘K settings rows (M1.T11 step 4, R-012 AC2 "settings rows are searchable"): the 13 Settings sections of S-21
// and the searchable rows index. M1.T11 ships the General rows that exist today (settings-map §1: Send with,
// Plain-text composer, Show context usage); M1.T22's `SettingsRegistry` registers every row through
// `SettingsRowsIndex.register(_:)` and consumes `SettingsNavigator.pending` to open Settings at that row.
import AntiChatDesign
import CommandPaletteKit
import Observation
import SwiftUI

/// The Settings sections, in S-21 order (`set.*` copy keys).
public enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case general, appearance, capabilities, evil, voice, personalization, tools, skills, privacy, storage, updates,
         shortcuts, about

    public var title: CopyKey {
        switch self {
        case .general: CopyKey("set.general")
        case .appearance: CopyKey("set.appearance")
        case .capabilities: CopyKey("set.capabilities")
        case .evil: CopyKey("set.evil")
        case .voice: CopyKey("set.voice")
        case .personalization: CopyKey("set.personalization")
        case .tools: CopyKey("set.tools")
        case .skills: CopyKey("set.skills")
        case .privacy: CopyKey("set.privacy")
        case .storage: CopyKey("set.storage")
        case .updates: CopyKey("set.updates")
        case .shortcuts: CopyKey("set.shortcuts")
        case .about: CopyKey("set.about")
        }
    }

    /// SF Symbol for the section (Settings sidebar and ⌘K rows).
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .capabilities: "square.stack.3d.up"
        case .evil: "flame"
        case .voice: "waveform"
        case .personalization: "person.crop.circle"
        case .tools: "wrench.and.screwdriver"
        case .skills: "sparkles"
        case .privacy: "hand.raised"
        case .storage: "internaldrive"
        case .updates: "arrow.triangle.2.circlepath"
        case .shortcuts: "keyboard"
        case .about: "questionmark.circle"
        }
    }
}

/// One searchable settings row: `{key, section, label key}` (M1.T22 `SettingsRegistry` adds default and R-ID).
public struct SettingsRowEntry: Identifiable, Hashable, Sendable {
    /// The row's settings key (`Defaults.Keys` name), unique across sections.
    public var id: String
    public var section: SettingsSection
    public var label: CopyKey
    /// Extra words the row is found by (English; synonyms of the label).
    public var keywords: [String]

    public init(id: String, section: SettingsSection, label: CopyKey, keywords: [String] = []) {
        self.id = id
        self.section = section
        self.label = label
        self.keywords = keywords
    }
}

/// The rows ⌘K searches. M1.T22 replaces the seed with the full registry.
@MainActor
public enum SettingsRowsIndex {
    /// Every row of M1.T22's `SettingsRegistry` (label, section, keywords).
    public static let seed: [SettingsRowEntry] = SettingsRegistry.paletteRows

    public private(set) static var rows: [SettingsRowEntry] = seed

    /// Adds rows (a row with an existing id replaces it).
    public static func register(_ new: [SettingsRowEntry]) {
        let ids = Set(new.map(\.id))
        rows = rows.filter { !ids.contains($0.id) } + new
    }

    /// Restores the seed (tests).
    public static func reset() { rows = seed }
}

/// Where Settings should open (section and optional row). The palette writes it before opening Settings;
/// M1.T22's Settings scene reads it (and clears it) when it appears.
@MainActor
@Observable
public final class SettingsNavigator {
    public static let shared = SettingsNavigator()

    public struct Request: Equatable, Sendable {
        public var section: SettingsSection
        public var rowID: String?

        public init(section: SettingsSection, rowID: String?) {
            self.section = section
            self.rowID = rowID
        }
    }

    public private(set) var pending: Request?
    /// Number of open requests made (probe and tests).
    public private(set) var requestCount = 0

    public func request(_ section: SettingsSection, row: String? = nil) {
        pending = Request(section: section, rowID: row)
        requestCount += 1
    }

    /// The Settings scene takes the request.
    public func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

/// Settings matches for the palette: sections (as "open settings page" actions) and rows.
@MainActor
enum SettingsRowsProvider {
    /// Rows whose label, section or keywords fuzzy-match `query` (all rows for an empty query), best first.
    static func rows(matching query: String, rows: [SettingsRowEntry] = SettingsRowsIndex.rows) -> [PaletteItem] {
        let scored: [(PaletteItem, Int)] = rows.compactMap { row in
            let label = row.label.string()
            let section = row.section.title.string()
            guard let score = PaletteMatch.score(query, fields: [label, section] + row.keywords) else { return nil }
            let item = PaletteItem(id: "setting.\(row.id)", kind: .setting(row.section, rowID: row.id),
                                   group: .settings, title: label, subtitle: section,
                                   symbol: row.section.symbol)
            return (item, score)
        }
        return PaletteMatch.ranked(scored)
    }
}

/// Fuzzy matching for actions and settings rows (CommandPaletteKit's `paletteFuzzyScore`). Loose subsequence
/// matches count only for short queries ("nc" → New chat), so a word like "send with" does not pull in rows that
/// merely contain its letters in order.
enum PaletteMatch {
    /// Prefix and substring scores start at 350 in `paletteFuzzyScore`; subsequence scores are below.
    static let substringFloor = 350
    static let looseQueryLength = 4

    static func score(_ query: String, fields: [String]) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return 0 }
        let best = fields.compactMap { paletteFuzzyScore(q, $0) }.max()
        guard let best else { return nil }
        return best >= substringFloor || q.count <= looseQueryLength ? best : nil
    }

    /// Stable sort by score, best first (ties keep the provider order).
    static func ranked(_ scored: [(PaletteItem, Int)]) -> [PaletteItem] {
        scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map(\.element.0)
    }
}
