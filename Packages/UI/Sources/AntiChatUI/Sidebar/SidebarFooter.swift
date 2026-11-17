// SidebarFooter (components.md §1): the status pills (update, download, memory review, offline) and Settings, which
// opens the Settings window. Help, Report a problem and Check for updates are in Settings › General and the Help menu.
import AntiChatDesign
import SwiftUI

struct SidebarFooter: View {
    @State private var hovering = false
    @State private var downloads = DownloadsLaunch.status

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
        // The chat list scrolls under the footer: an opaque sidebar-coloured ground with a soft top edge, so the last
        // rows fade out above the pills instead of showing through them.
        .padding(.top, Spacing.space1)
        .background(Color.surfaceSidebar)
        .overlay(alignment: .top) {
            LinearGradient(colors: [Color.surfaceSidebar.opacity(0), Color.surfaceSidebar], startPoint: .top, endPoint: .bottom)
                .frame(height: Spacing.space5).offset(y: -Spacing.space5)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
        .modifier(DownloadSheetsModifier())
    }

    private var settingsButton: some View {
        Button { SettingsPresenter.shared.show() } label: {
            Label { Text(CopyKey("side.settings")).typeStyle(.subhead) } icon: {
                Image(systemName: "gearshape").frame(width: 18)
            }
            .foregroundStyle(Color.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, Spacing.space2)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(hovering ? Color.surfaceHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(verbatim: "\(CopyKey("side.settings").string()) ⌘,"))
        .padding(.horizontal, Spacing.space2)
        .padding(.vertical, Spacing.space2)
        .probeID("sidebar.settings")
    }
}

/// M2.T09: the policy's sheets — disk short (`download.diskFull`) and metered network (`download.expensiveAsk`).
private struct DownloadSheetsModifier: ViewModifier {
    @State private var model = DownloadsLaunch.status

    func body(content: Content) -> some View {
        let s = model.status
        content
            .sheet(isPresented: Binding(get: { s.holds.contains(.disk) && s.diskGBNeeded != nil && !model.askDismissed },
                                        set: { if !$0 { model.askDismissed = true } })) {
                DiskShortSheet(gbNeeded: s.diskGBNeeded ?? 0, onOpenStorage: {
                    model.askDismissed = true
                    SettingsNavigator.shared.request(.privacy, row: "storage.cleanUp")
                    SettingsPresenter.shared.show()
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
