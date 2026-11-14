// Settings window (M1.T22 step 1; screens S-21, R-100): the app's `Settings` scene (⌘, opens it; SwiftUI
// `openSettings` from the sidebar footer and ⌘K), System-Settings look — SettingsSidebar (13 sections in
// settings-map order + search) beside a grouped form of SettingsRows. Every control writes its Defaults key
// directly (no Apply). A section whose content arrives later shows its M1 rows or a disabled one-line
// "arrives …" row, never an empty pane. Requests from ⌘K / the footer menu (`SettingsNavigator`) open the
// section and reveal the row (AT-012 leg 2).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import SwiftUI

/// What the Settings window needs from the app (the shared chat database for Privacy & Data).
public struct SettingsContext {
    public var chats: ChatListService?

    public init(chats: ChatListService?) { self.chats = chats }
}

public struct SettingsRootView: View {
    @Bindable private var model: SettingsModel
    private let context: SettingsContext
    private let navigator = SettingsNavigator.shared

    public init(context: SettingsContext, model: SettingsModel = .shared) {
        self.context = context
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(model: model)
                .frame(width: 220)
            Divider()
            SettingsDetail(model: model, context: context)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 540, idealHeight: 620)
        .background(Color.surfaceCanvas)
        .onAppear {
            model.consume(navigator)
            // VQ (S-21 Storage): measure while the user is still on another section (cached report shown meanwhile).
            if FeatureFlag.storageDashboard.isEnabled() { StorageModel.prewarm(database: context.chats?.database) }
        }
        .onChange(of: navigator.requestCount) { model.consume(navigator) }
        .sheet(isPresented: $model.showingReport) { ReportProblemSheet { model.showingReport = false } }
        .sheet(isPresented: $model.showingHelp) { HelpGuideSheet(offline: false) { model.showingHelp = false } }
        .sheet(isPresented: $model.showingExportLogs) { ExportLogsSheet(database: nil) { model.showingExportLogs = false } }  // M8.T09
        // A container of its own: on the bare HStack SwiftUI stamped "settings.root" over the search field and both
        // scroll views, hiding settings.search from XCUITest (Q-015 catch-up).
        .accessibilityElement(children: .contain)
        // Names the hosting group (audit "no description", S-21); the window's title stays the section's (navigationTitle).
        .windowAccessibilityTitle(CopyKey("side.settings").string(), windowTitle: false)
        .probeID("settings.root")
    }
}

/// The selected section's form, scrolled to the revealed row.
struct SettingsDetail: View {
    @Bindable var model: SettingsModel
    let context: SettingsContext

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                section
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .environment(\.settingsHighlight, model.highlightedRow)
            .onChange(of: model.revealGeneration) { reveal(proxy) }
            .onAppear { reveal(proxy) }
            .id(model.selection)  // a fresh form per section (scroll position starts at the top)
        }
        .navigationTitle(Text(model.selection.title))
        .probeID("settings.detail.\(model.selection.rawValue)")
    }

    @ViewBuilder private var section: some View {
        switch model.selection {
        case .general: GeneralSection()
        case .appearance: AppearanceSection()
        case .capabilities: CapabilitiesSection(model: model, database: context.chats?.database)
        case .evil: EvilSection()
        case .voice: VoiceSection()
        case .personalization: PersonalizationSection(chats: context.chats)
        case .tools: ToolsSection(database: context.chats?.database)
        case .skills: SkillsSection()
        case .privacy: PrivacyDataView(model: model, chats: context.chats)
        case .storage: StorageSection(database: context.chats?.database)
        case .updates: UpdatesSection()
        case .shortcuts: ShortcutsSection()
        case .about: AboutSection(model: model)
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        guard let row = model.highlightedRow else { return }
        let generation = model.revealGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))  // the new section's rows are laid out
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .center) }
            try? await Task.sleep(for: .seconds(2.5))
            if model.revealGeneration == generation { model.highlightedRow = nil }
        }
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

/// A section that has only its "arrives …" row in M1 (the row label is the sentence; disabled).
struct PlaceholderSection: View {
    let rowID: String

    var body: some View {
        Section {
            if let spec = SettingsRegistry.row(rowID) {
                HStack(spacing: Spacing.space2) {
                    Image(systemName: "clock").foregroundStyle(Color.textTertiary).accessibilityHidden(true)
                    Text(spec.label).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, Spacing.space2)
                .id(spec.id)
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .probeID("settings.row.\(spec.id)")
            }
        }
    }
}
