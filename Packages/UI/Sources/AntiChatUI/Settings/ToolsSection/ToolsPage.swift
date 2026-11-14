// Settings → Tools & Connections, top (M7.T14 steps 3, 5; R-268 AC1/AC3; S-21 §7; settings-map §7): every built-in
// tool with an on/off switch — Web search (WebSearchRows: the gate's `.search` category, consent, Safe search…),
// Create image, Create video (ToolSwitches, `toolImage` / `toolVideo`), Create files and Run code (M6.T19's
// FileToolsSettingsRows: `createFilesEnabled`, `runCodeEnabled`, install + network for code), Memory (`toolMemory`) — and
// Tool access ("Load tools when needed" default / "Always offer all enabled tools", which warns on T0–T2 with
// `set.tools.access.allWarn`). Each connection and its tools (on/off + Always allow / Ask / Block) follow in
// ConnectionsPage. Turning a tool off removes it from every chat's prompt; "+" → Tools › overrides it per chat only.
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import SwiftUI

/// The page's state, kept apart from the view so the in-process tests can drive it (ToolsPageModelTests).
@MainActor
@Observable
final class ToolsPageModel {
    /// The switch rows this page draws itself (Create files / Run code are FileToolsSettingsRows, M6.T19).
    static let rows: [ToolGroup] = [.image, .video, .memory]
    /// Every tool the page lists, in settings-map order (R-268 AC1).
    static let listed: [ToolGroup] = [.web, .image, .video, .files, .code, .memory]

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

struct ToolsPage: View {
    var database: AppDatabase?
    @State private var model = ToolsPageModel()
    /// VQ (S-21 Tools): a media tool whose pack cannot run on this Mac is shown off and disabled, with the reason.
    var packs: PackManagementModel = .shared

    private func unavailableReason(_ g: ToolGroup) -> CopyText? {
        let pack: ModelPack
        switch g {
        case .image: pack = .photo
        case .video: pack = .video
        default: return nil
        }
        switch packs.state(pack) {
        case .notAvailable(let reason): return CopyText(CopyKey("set.cap.notAvailable"), ["reason": reason.string])
        case .comingSoon: return CopyText(CopyKey("set.cap.comingSoon"))
        default: return nil
        }
    }

    var body: some View {
        Section { WebSearchRows() }
        Section {
            row(.image)
            row(.video)
            FileToolsSettingsRows(database: database)  // M6.T19: Create files, Run code (+ install), Network for code
            row(.memory)
            // M9.T03: the two-line note in `text.primary` (footnote size keeps it secondary in the hierarchy).
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
        } header: {
            Text(CopyKey("set.tools.builtin"))
        } footer: {
            Text(CopyKey("set.tools.builtin.note")).typeStyle(.caption).foregroundStyle(Color.textSecondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: ToolSwitches.didChange)) { _ in model.reload() }
        // Q-015 r5: the anchor only. An identifier on a Section is set on every row of it, so `probeID` here renamed
        // each row (settings.row.toolImage …, the Tool access warning) to "settings.toolsPage" for accessibility
        // clients: the warning was shown but unreachable by its id (AT-268 c3 UI leg).
        .probeAnchor("settings.toolsPage")
    }

    private func row(_ g: ToolGroup) -> some View {
        let reason = unavailableReason(g)
        return SettingsItem(ToolsPageModel.rowID(g)) {
            Toggle(isOn: Binding(get: { reason == nil && model.isOn(g) }, set: { model.set(g, $0) })) { Text(CopyKey(g.copyKey)) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .disabled(reason != nil)
                .probeID("settings.control.\(ToolsPageModel.rowID(g))")
        }
        .modifier(UnavailableNote(reason: reason))
    }
}

/// The reason under a disabled tool row ("Not available on this Mac · Needs 24 GB memory").
private struct UnavailableNote: ViewModifier {
    let reason: CopyText?
    func body(content: Content) -> some View {
        if let reason {
            VStack(alignment: .leading, spacing: 2) {
                content
                Text(reason).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Spacing.space1)
                    .padding(.bottom, Spacing.space1)
            }
        } else {
            content
        }
    }
}
