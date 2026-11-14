// SidebarFooter (components.md §1): Settings, which opens the footer menu (M1.T22 step 6; R-100 AC3): Settings,
// Help (the bundled help placeholder until M10), Report a bug (the T10 report sheet), Check for updates (Settings →
// Updates; Sparkle in M10). StatusPill and NetworkIndicator join it with downloads (M2) and network status (M7);
// they are hidden states until then.
import AntiChatDesign
import SwiftUI

struct SidebarFooter: View {
    @Environment(\.openSettings) private var openSettings
    @State private var hovering = false
    @State private var menuShown = false
    @State private var showingHelp = false
    @State private var showingReport = false
    @State private var downloads = DownloadsLaunch.status

    enum Item: String, CaseIterable {
        case settings, help, report, updates

        var title: CopyKey {
            switch self {
            case .settings: CopyKey("side.settings")
            case .help: CopyKey("side.footer.help")
            case .report: CopyKey("side.footer.report")
            case .updates: CopyKey("side.footer.updates")
            }
        }

        var symbol: String {
            switch self {
            case .settings: "gearshape"
            case .help: "questionmark.circle"
            case .report: "ladybug"
            case .updates: "arrow.triangle.2.circlepath"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if downloads.status.noticeKey == "download.pausedConnection" {
                DownloadPausedNotice { Task { await DownloadsLaunch.policy?.retryNow() } }
            }
            UpdatePill()  // M10.T03 (R-219 AC2): Restart to update
            StatusPill()  // M2.T09 (R-204 AC2)
            MemoryReviewPill()  // M8.T03 step 7 (R-246): pending memory suggestions
            NetworkIndicator()  // M2.T03 (R-209 AC4)
            settingsButton
        }
        .modifier(DownloadSheetsModifier())
    }

    private var settingsButton: some View {
        Button { menuShown.toggle() } label: {
            Label { Text(CopyKey("side.settings")).typeStyle(.subhead) } icon: {
                Image(systemName: "gearshape").frame(width: 18)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, Spacing.space2)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering || menuShown ? Color.surfaceHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: "\(CopyKey("side.settings").string()) ⌘,"))
        .popover(isPresented: $menuShown, arrowEdge: .top) { menu }
        .padding(.horizontal, Spacing.space2)
        .padding(.vertical, Spacing.space2)
        .background(Color.surfaceSidebar)
        .probeID("sidebar.settings")
        .sheet(isPresented: $showingHelp) { HelpGuideSheet(offline: false) { showingHelp = false } }
        .sheet(isPresented: $showingReport) { ReportProblemSheet { showingReport = false } }
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Item.allCases, id: \.self) { item in
                FooterMenuRow(item: item) { choose(item) }
                if item == .settings { Divider().padding(.vertical, 2) }
            }
        }
        .padding(Spacing.space1)
        .frame(width: 220)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("footer.menu")
    }

    func choose(_ item: Item) {
        menuShown = false
        switch item {
        case .settings: openSettings()
        case .help: showingHelp = true
        case .report: showingReport = true
        case .updates:
            SettingsNavigator.shared.request(.updates)
            openSettings()
        }
    }
}

private struct FooterMenuRow: View {
    let item: SidebarFooter.Item
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label { Text(item.title).typeStyle(.callout) } icon: { Image(systemName: item.symbol).frame(width: 18) }
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .padding(.horizontal, Spacing.space2)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering ? Color.surfaceHover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .probeID("footer.\(item.rawValue)")
    }
}

/// M2.T09: the policy's sheets — disk short (`download.diskFull`) and metered network (`download.expensiveAsk`).
private struct DownloadSheetsModifier: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    @State private var model = DownloadsLaunch.status

    func body(content: Content) -> some View {
        let s = model.status
        content
            .sheet(isPresented: Binding(get: { s.holds.contains(.disk) && s.diskGBNeeded != nil && !model.askDismissed },
                                        set: { if !$0 { model.askDismissed = true } })) {
                DiskShortSheet(gbNeeded: s.diskGBNeeded ?? 0, onOpenStorage: {
                    model.askDismissed = true
                    SettingsNavigator.shared.request(.storage)
                    openSettings()
                }, onClose: { model.askDismissed = true })
            }
            .sheet(isPresented: Binding(get: { s.holds.contains(.expensive) && !model.askDismissed },
                                        set: { if !$0 { model.askDismissed = true } })) {
                DownloadAskSheet(bytes: s.askBytes ?? 0, onDownload: {
                    model.askDismissed = true
                    Task { await DownloadsLaunch.policy?.approveExpensive() }
                }, onLater: { model.askDismissed = true })
            }
            .onChange(of: s.holds) { _, _ in model.askDismissed = false }
    }
}
