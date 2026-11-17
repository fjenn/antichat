// The Settings window's state (M1.T22): selected section, search query, the row to reveal (from ⌘K or a search
// result) and the Privacy sheets. One Settings window per app, so one shared model; the ⌘K palette and the
// sidebar footer reach it through `SettingsNavigator` (M1.T11).
import Observation
import SwiftUI

@MainActor
@Observable
public final class SettingsModel {
    public static let shared = SettingsModel()

    public var selection: SettingsSection = .general
    public var query = ""
    /// The row to scroll to and highlight (cleared after the highlight fades).
    public var highlightedRow: String?
    /// Bumped on every reveal so the detail scrolls even when the same row is revealed twice.
    public private(set) var revealGeneration = 0
    /// The pages whose "Advanced" group is open (each collapsed by default, R-100 AC4).
    public var advancedOpen: Set<SettingsSection> = []
    /// Capabilities → Advanced.
    public var advancedExpanded: Bool {
        get { advancedOpen.contains(.capabilities) }
        set { setAdvanced(.capabilities, newValue) }
    }
    /// General → About → Keyboard shortcuts (the rebinding sheet).
    public var showingShortcuts = false
    public var showingArchived = false
    public var showingDeleteAll = false
    /// M8.T01: Privacy & Data → Restore from backup.
    public var showingRestore = false
    /// M8.T06: the import sheet (Settings › Privacy & Data, File › Import Chats…).
    public var showingImport = false
    /// M8.T07: Export all data sheet.
    public var showingExport = false
    public var confirmingArchiveAll = false
    public var showingReport = false
    public var showingHelp = false
    /// M8.T09: About & Help › System report; Privacy & Data / About › Export logs.
    public var showingSystemReport = false
    public var showingExportLogs = false
    /// Requests consumed from `SettingsNavigator` (probe).
    public private(set) var consumed = 0

    public init() {}

    /// Opens `section`, revealing `row` when given (search result, ⌘K settings row, footer menu target).
    /// A registered row opens on its own page, whatever `section` says (links written before pages were merged).
    public func open(_ section: SettingsSection, row: String? = nil) {
        let section = row.flatMap { SettingsRegistry.row($0)?.section } ?? section
        selection = section
        query = ""
        highlightedRow = row
        if let row {
            // The row is in the page's Advanced group, or is the group itself ("capabilities.advanced").
            if SettingsRegistry.row(row)?.advanced == true || row == "\(section.rawValue).advanced" { advancedOpen.insert(section) }
            revealGeneration += 1
        }
    }

    public func setAdvanced(_ section: SettingsSection, _ open: Bool) {
        if open { advancedOpen.insert(section) } else { advancedOpen.remove(section) }
    }

    func advancedBinding(_ section: SettingsSection) -> Binding<Bool> {
        Binding(get: { self.advancedOpen.contains(section) }, set: { self.setAdvanced(section, $0) })
    }

    /// Takes the palette's / footer's pending request, if any.
    public func consume(_ navigator: SettingsNavigator = .shared) {
        guard let r = navigator.take() else { return }
        consumed += 1
        open(r.section, row: r.rowID)
    }

    public var results: [SettingsRowSpec] { SettingsSearch.results(query) }
}
