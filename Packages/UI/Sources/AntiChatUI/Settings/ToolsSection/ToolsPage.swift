// Settings → Capabilities → Tools (M7.T14 steps 3, 5; R-268 AC1/AC3; settings-map §7): one switch per feature —
// Web search (WebSearchRows: the gate's `.search` category, consent), Create files and Analyse data (M6.T19's
// FileToolsSettingsRows), Memory (`toolMemory`). Creating images and video has no switch here: the Images and Video
// packs above are those switches (`toolImage` / `toolVideo` follow the pack, PackManagementModel.syncTools).
// Advanced: Safe search, location and the hint for search, Allow network for code, and Tool access ("Load tools when
// needed" default / "Always offer all enabled tools", which warns on T0–T2). Turning a tool off removes it from every
// chat's prompt.
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import SwiftUI

/// The page's state, kept apart from the view so the in-process tests can drive it (ToolsPageModelTests).
@MainActor
@Observable
final class ToolsPageModel {
    /// The switch rows this page draws itself (Create files / Analyse data are FileToolsSettingsRows, M6.T19).
    static let rows: [ToolGroup] = [.memory]
    /// Every tool the page lists, in order (image and video are the Images and Video packs' switches).
    static let listed: [ToolGroup] = [.web, .files, .code, .memory]

    @ObservationIgnored let switches: ToolSwitches
    let tier: DeviceTier
    private(set) var on: [ToolGroup: Bool] = [:]
    private(set) var access: ToolAccess = .default

    init(switches: ToolSwitches = .shared, tier: DeviceTier = .current()) {
        self.switches = switches
        self.tier = tier
        reload()
    }

    func reload() {
        on = Dictionary(uniqueKeysWithValues: Self.rows.map { ($0, switches.isOn($0)) })
        access = switches.access
    }

    func isOn(_ g: ToolGroup) -> Bool { on[g] ?? g.defaultOn }

    func set(_ g: ToolGroup, _ value: Bool) {
        switches.setOn(g, value)
        on[g] = value
    }

    func setAccess(_ a: ToolAccess) {
        switches.access = a
        access = a
    }

    /// `set.tools.access.allWarn` under the picker: "Always offer all" chosen on T0–T2.
    var showsAllWarning: Bool { access == .all && ToolAccess.warns(tier) }

    static func rowID(_ g: ToolGroup) -> String {
        switch g {
        case .web: "webSearch"
        case .files: "createFiles"
        case .code: "runCode"
        case .image, .video, .memory: g.defaultsKey ?? g.rawValue
        }
    }
}

/// Capabilities → Tools: one switch per feature on the page; Advanced has the web-search options, Allow network for
/// code and Tool access.
struct ToolRows: View {
    let part: SettingsPart
    var database: AppDatabase?
    @State private var model = ToolsPageModel()

    var body: some View {
        Group {
            if part == .main {
                WebSearchRows(part: .main)
                FileToolsSettingsRows(part: .main, database: database)  // M6.T19: Create files, Analyse data (+ install)
                row(.memory)
            } else {
                WebSearchRows(part: .advanced)
                FileToolsSettingsRows(part: .advanced, database: database)
                // VQ: the note describes the choice that is on (it described "when needed" under "Always offer all" too).
                SettingsItem("toolAccess", description: CopyKey(model.access == .all ? "set.tools.access.all.note" : "set.tools.access.note"),
                             descriptionColor: .textPrimary) {
                    Picker(selection: Binding(get: { model.access }, set: { model.setAccess($0) })) {
                        Text(CopyKey("set.tools.access.whenNeeded")).tag(ToolAccess.whenNeeded)
                        Text(CopyKey("set.tools.access.all")).tag(ToolAccess.all)
                    } label: { Text(CopyKey("set.tools.access")) }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                        .probeID("settings.control.toolAccess")
                }
                if model.showsAllWarning {
                    Label { Text(CopyKey("set.tools.access.allWarn")) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .typeStyle(.callout)
                        .foregroundStyle(Color.warning)
                        .padding(.horizontal, Spacing.space1)
                        .probeID("settings.toolAccess.warning")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ToolSwitches.didChange)) { _ in model.reload() }
    }

    private func row(_ g: ToolGroup) -> some View {
        let id = ToolsPageModel.rowID(g)
        return SettingsItem(id, description: SettingsRegistry.row(id)?.note) {
            Toggle(isOn: Binding(get: { model.isOn(g) }, set: { model.set(g, $0) })) { Text(CopyKey(g.copyKey)) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .probeID("settings.control.\(id)")
        }
    }
}
