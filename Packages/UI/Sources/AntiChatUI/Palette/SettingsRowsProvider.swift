// The Settings pages, the searchable rows index (the search field in Settings) and `SettingsNavigator`, which opens
// Settings at a page or row. M1.T22's `SettingsRegistry` registers every row through `SettingsRowsIndex.register(_:)`.
import AntiChatDesign
import CommandPaletteKit
import Observation
import SwiftUI

/// The Settings pages, in sidebar order. Six since the 2026-11 simplification: Appearance, Updates, Keyboard shortcuts
/// and About live on General; Evil Mode, Voice and the tool switches on Capabilities; Storage on Privacy & Data.
/// A request for a row always lands on the row's own page (`SettingsNavigator.request`).
public enum SettingsSection: String, CaseIterable, Hashable, Sendable {
    case general, capabilities, connections, skills, personalization, privacy

    /// The old "Tools & Connections" page: its switches are on Capabilities now. Kept so a link written against the
    /// old page still compiles; with a row it opens that row's page.
    public static let tools = SettingsSection.capabilities

    public var title: CopyKey {
        switch self {
        case .general: CopyKey("set.general")
        case .capabilities: CopyKey("set.capabilities")
        case .connections: CopyKey("conn.title")
        case .skills: CopyKey("set.skills")
        case .personalization: CopyKey("set.personalization")
        case .privacy: CopyKey("set.privacy")
        }
    }

    /// SF Symbol for the section (Settings sidebar and ⌘K rows).
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capabilities: "square.stack.3d.up"
        case .connections: "app.connected.to.app.below.fill"
        case .skills: "sparkles"
        case .personalization: "person.crop.circle"
        case .privacy: "hand.raised"
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

    /// A row is opened on its own page, whatever `section` says (links written before pages were merged keep working).
    public func request(_ section: SettingsSection, row: String? = nil) {
        pending = Request(section: row.flatMap { SettingsRegistry.row($0)?.section } ?? section, rowID: row)
        requestCount += 1
    }

    /// The Settings scene takes the request.
    public func take() -> Request? {
        defer { pending = nil }
        return pending
    }
}

/// Fuzzy matching for settings rows (CommandPaletteKit's `paletteFuzzyScore`). Loose subsequence
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

}
