// SettingsSearch (M1.T22 step 2; components §6 SettingsSidebar "search results"): the Settings window's search
// field over `SettingsRegistry` — label, section title and keywords, the same matcher the ⌘K settings provider
// uses (`PaletteMatch`), so a row found in ⌘K is found here and vice versa.
import AntiChatDesign
import Foundation

public enum SettingsSearch {
    /// Rows matching `query`, best first (empty query: none).
    public static func results(_ query: String, rows: [SettingsRowSpec] = SettingsRegistry.rows) -> [SettingsRowSpec] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let scored: [(SettingsRowSpec, Int)] = rows.compactMap { row in
            guard let s = PaletteMatch.score(q, fields: [row.label.string(), row.section.title.string()] + row.keywords)
            else { return nil }
            return (row, s)
        }
        return scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 > b.element.1 : a.offset < b.offset
        }.map(\.element.0)
    }
}
