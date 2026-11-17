// Settings (S-21, R-100): a full-window view over the chat, inside the main window (`SettingsPresenter`, shown by
// `MainWindow.settingsOverlay`; ⌘,, the sidebar footer and every link to a page open it; "Back to chat" and Esc close
// it). SettingsSidebar (six pages + search) beside the page: a grouped form of SettingsRows, or one of the two
// directory pages (Connections, Skills: DirectoryViews).
// Every control writes its Defaults key directly (no Apply). Every page starts the same way: its title and a one-line
// subtitle (`PageHeader`), then its groups. Each page shows what most people need; the rest sits in one collapsed
// "Advanced" group at its bottom (`AdvancedGroup`). Buttons in a row are all the quiet `SettingsButtonStyle`; the
// filled `.primary` pill is kept for a page's one main action (Restart to update). Requests from ⌘K / the footer menu
// (`SettingsNavigator`) open the page and reveal the row, opening Advanced when the row is inside it (AT-012 leg 2).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import SwiftUI

/// What Settings needs from the app (the shared chat database for Privacy & Data).
public struct SettingsContext {
    public var chats: ChatListService?

    public init(chats: ChatListService?) { self.chats = chats }
}

public struct SettingsRootView: View {
    @Bindable private var model: SettingsModel
    private let context: SettingsContext
    private let navigator = SettingsNavigator.shared
    private let onClose: @MainActor () -> Void

    /// `onClose`: "Back to chat" and Esc.
    public init(context: SettingsContext, model: SettingsModel = .shared,
                onClose: @escaping @MainActor () -> Void = { SettingsPresenter.shared.dismiss() }) {
        self.context = context
        self.model = model
        self.onClose = onClose
    }

    /// Esc: a typed search is cleared first, then Settings closes. Its sheets and menus take their own Esc.
    private func escape() {
        if model.query.isEmpty { onClose() } else { model.query = "" }
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model, onClose: onClose)
                .frame(width: Self.sidebarWidth)
            Divider().ignoresSafeArea(edges: .top)
            SettingsDetail(model: model, context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Up to the window's top edge: under the title bar it is Settings too, not the chat's toolbar.
        .background(Color.surfaceCanvas, ignoresSafeAreaEdges: .top)
        .scrollEdgeEffectStyle(.hard, for: .top)  // a scrolled page is cut at the title bar, not blurred over it
        .background {
            Button("") { escape() }  // a11y-lint: ok a key equivalent only (Esc); "Back to chat" is the reachable control
                .accessibilityIdentifier("settings.escape")
                .keyboardShortcut(.cancelAction)
                .accessibilityHidden(true)
                .hidden()  // a key equivalent only, as the sidebar's ⌘F
        }
        .onAppear {
            model.consume(navigator)
            // VQ (S-21 Storage): measure while the user is still on another section (cached report shown meanwhile).
            if FeatureFlag.storageDashboard.isEnabled() { StorageModel.prewarm(database: context.chats?.database) }
        }
        .onChange(of: navigator.requestCount) { model.consume(navigator) }
        .sheet(isPresented: $model.showingReport) { ReportProblemSheet { model.showingReport = false } }
        .sheet(isPresented: $model.showingHelp) { HelpGuideSheet(offline: false) { model.showingHelp = false } }
        .sheet(isPresented: $model.showingExportLogs) { ExportLogsSheet(database: nil) { model.showingExportLogs = false } }  // M8.T09
        .sheet(isPresented: $model.showingShortcuts) { ShortcutsSheet { model.showingShortcuts = false } }
        // A container of its own: on the bare HStack SwiftUI stamped "settings.root" over the search field and both
        // scroll views, hiding settings.search from XCUITest (Q-015 catch-up).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CopyKey("side.settings")))  // names the group (audit "no description", S-21)
        .probeID("settings.root")
    }

    static let sidebarWidth: CGFloat = 200
}

/// The selected page, scrolled to the revealed row.
struct SettingsDetail: View {
    @Bindable var model: SettingsModel
    let context: SettingsContext

    var body: some View {
        ScrollViewReader { proxy in
            page
                .environment(\.settingsHighlight, model.highlightedRow)
                .onChange(of: model.revealGeneration) { reveal(proxy) }
                .onAppear { reveal(proxy) }
                .id(model.selection)  // a fresh page per section (scroll position starts at the top)
                .buttonStyle(SettingsButtonStyle())
        }
        .probeID("settings.detail.\(model.selection.rawValue)")
    }

    @ViewBuilder private var page: some View {
        if model.selection == .connections {
            ConnectionsPage().modifier(DirectoryColumn())
        } else if model.selection == .skills {
            SkillsPage().modifier(DirectoryColumn())
        } else {
            Form {
                // General's first group has a heading of its own right under the header: room between the two.
                Section {} header: {
                    PageHeader(section: model.selection).padding(.bottom, model.selection == .general ? Spacing.space4 : 0)
                }
                rows
            }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                // The window is as wide as the chat's; a form's rows stay a readable width, centred.
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var rows: some View {
        let database = context.chats?.database
        switch model.selection {
        case .general: GeneralSection(model: model)
        case .capabilities: CapabilitiesSection(model: model, database: database)
        case .connections, .skills: EmptyView()
        case .personalization: PersonalizationSection(model: model, chats: context.chats)
        case .privacy: PrivacyDataView(model: model, chats: context.chats)
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let row = model.highlightedRow else { return }
        let generation = model.revealGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))  // the new page's rows (and an opened Advanced group) are laid out
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .center) }
            try? await Task.sleep(for: .seconds(2.5))
            if model.revealGeneration == generation { model.highlightedRow = nil }
        }
    }
}

/// The two directory pages (Connections, Skills) use the window's width up to two comfortable columns, centred.
private struct DirectoryColumn: ViewModifier {
    static let maxWidth: CGFloat = 1000

    func body(content: Content) -> some View {
        content.frame(maxWidth: Self.maxWidth).frame(maxWidth: .infinity)
    }
}

// MARK: Row wrapper

extension EnvironmentValues {
    /// The row Settings is revealing (highlighted for a moment).
    @Entry var settingsHighlight: String? = nil
}

/// A registry row: Design's `SettingsRow` + scroll id, probe anchor and the reveal highlight.
struct SettingsItem<Control: View>: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let spec: SettingsRowSpec
    var description: CopyText?
    var disabledReason: CopyText?
    var descriptionColor: Color = .textSecondary
    let control: Control
    @Environment(\.settingsHighlight) private var highlight
    @Environment(\.colorScheme) private var scheme

    init(_ id: String, description: CopyKey? = nil, disabledReason: CopyKey? = nil, descriptionColor: Color = .textSecondary,
         @ViewBuilder control: () -> Control) {
        guard let spec = SettingsRegistry.row(id) else { preconditionFailure("SettingsRegistry has no row \(id)") }
        self.spec = spec
        self.description = description.map { CopyText($0) }
        let reason = disabledReason ?? (spec.enabled ? nil : CopyKey("set.later"))
        self.disabledReason = reason.map { CopyText($0) }
        self.descriptionColor = descriptionColor
        self.control = control()
    }

    var body: some View {
        SettingsRow(CopyText(spec.label), description: description, disabledReason: disabledReason,
                    descriptionColor: descriptionColor, descriptionIdentifier: "settings.row.\(spec.id).description") { control }
            .padding(.horizontal, Spacing.space1)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(highlight == spec.id ? accentPreset.color.opacity(scheme == .dark ? 0.30 : 0.14) : .clear)  // VQ: visible in dark
                    .padding(-Spacing.space1)
            )
            .animation(.easeOut(duration: 0.3), value: highlight == spec.id)
            .id(spec.id)
            .probeID("settings.row.\(spec.id)")
    }
}

extension SettingsItem {
    /// A description with arguments (`{size}` …).
    init(_ id: String, descriptionText: CopyText, @ViewBuilder control: () -> Control) {
        self.init(id, control: control)
        description = descriptionText
    }
}

extension SettingsItem where Control == EmptyView {
    init(_ id: String, description: CopyKey? = nil, disabledReason: CopyKey? = nil) {
        self.init(id, description: description, disabledReason: disabledReason) { EmptyView() }
    }
}

/// A page's one "Advanced" group: collapsed by default, at the bottom, holding everything most people never change.
struct AdvancedGroup<Content: View>: View {
    @Bindable var model: SettingsModel
    let section: SettingsSection
    @ViewBuilder var content: Content

    private var anchor: String { "\(section.rawValue).advanced" }

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: model.advancedBinding(section)) {
                content
            } label: {
                // In a grouped Form the chevron sits at the trailing edge and the label did nothing on click (Q-015 r5);
                // the label toggles the group, as a System Settings row does. Highlight and ids stay on the label: on the
                // DisclosureGroup they were stamped over every row inside it.
                Button { model.setAdvanced(section, !model.advancedOpen.contains(section)) } label: {
                    Text(CopyKey("set.cap.advanced")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(HighlightRow(id: anchor))
                .probeID("settings.row.\(anchor)")
            }
            .disclosureGroupStyle(.accessible)  // M9.T03: the triangle's press action
            .id(anchor)
        }
    }
}

/// A group of rows inside Advanced that stays closed until asked for (the model pickers, the installed models), so
/// Advanced itself stays short. The whole row toggles, with a chevron at its leading edge.
struct SubDisclosure<Content: View>: View {
    let title: String
    let id: String
    @Binding var open: Bool
    @ViewBuilder var content: Content

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Spacing.space2) {
                Image(systemName: "chevron.right").typeStyle(.caption).foregroundStyle(Color.textSecondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .accessibilityHidden(true)
                Text(verbatim: title).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.space1)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(verbatim: open ? "1" : "0"))
        .probeID("settings.row.\(id)")
        if open { content }
    }
}

/// The top of every Settings page: its title, then one line saying what the page is for.
struct PageHeader: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(section.title).typeStyle(.title3).foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(LocalizedStringKey(section.subtitle.string()))
                .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)  // R-091 AC1: the privacy statement can be copied
                .probeID(section.subtitleProbe)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
        .id(section.rawValue)
    }
}

extension SettingsSection {
    /// The one line under the page's title.
    var subtitle: CopyKey {
        switch self {
        case .general: CopyKey("set.general.intro")
        case .capabilities: CopyKey("set.capabilities.intro")
        case .connections: CopyKey("conn.intro")
        case .skills: CopyKey("skills.intro")
        case .personalization: CopyKey("set.pers.intro")
        case .privacy: CopyKey("privacy.statement")  // R-091 AC1: the page's first paragraph, verbatim
        }
    }

    /// The subtitle's id (the ones the probes and UI tests already knew stay).
    var subtitleProbe: String {
        switch self {
        case .connections: "connections.intro"
        case .skills: "settings.row.skills"
        case .privacy: "privacy.statement"
        default: "settings.intro.\(rawValue)"
        }
    }
}

/// The one button look inside Settings pages: a quiet pill (destructive actions in red). A page's single main action,
/// where it has one, uses Design's filled `.primary` instead.
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SettingsButtonBody(configuration: configuration) }
}

private struct SettingsButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var hovering = false

    private var small: Bool { controlSize == .small || controlSize == .mini }

    var body: some View {
        configuration.label
            .font(.system(size: small ? 11 : 13, weight: .medium))
            .foregroundStyle(configuration.role == .destructive ? Color.danger : Color.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, small ? Spacing.space2 + 1 : Spacing.space3)
            .padding(.vertical, small ? 3 : Spacing.space1)
            .background {
                // Circular ends: a continuous capsule's 1 pt border drew stray ticks where the ends meet the sides.
                Capsule(style: .circular).fill(Color.surfaceRaised)
                Capsule(style: .circular)
                    .fill(Color.textPrimary.opacity(configuration.isPressed ? 0.12 : hovering && isEnabled ? 0.06 : 0))
                Capsule(style: .circular).strokeBorder(Color.borderSubtle)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

/// A quiet heading between the kinds of rows inside an Advanced group.
struct AdvancedHeading: View {
    let title: CopyKey
    init(_ title: String) { self.title = CopyKey(title) }

    var body: some View {
        Text(title).typeStyle(.caption).foregroundStyle(Color.textSecondary)
            .padding(.top, Spacing.space2)
            .padding(.horizontal, Spacing.space1)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A group's heading: one style on every page.
struct GroupHeader: View {
    let title: CopyKey
    init(_ title: String) { self.title = CopyKey(title) }

    var body: some View {
        Text(title).typeStyle(.headline).foregroundStyle(Color.textPrimary)
    }
}

/// Which rows of a group to draw: the ones on the page, or the ones inside the page's Advanced group.
enum SettingsPart { case main, advanced }
