// Settings › Privacy & Data (M8.T08; R-091, NFR-PR4; settings-map §9; S-21): assembles every row in settings-map
// order — the statement (R-091 AC1, verbatim, selectable) → Offline only → Network activity (per category, R-091 AC2)
// → Location (read-only, R-091 AC3) → New chats are incognito → Incognito personalization → Import → Export all →
// Restore from backup → Archived chats → Archive all / Delete all (typed DELETE) → Auto-archive → Crash reports →
// Export logs. Behaviour of the rows lives with their tasks (M1.T22, M2.T03, M8.T01/T06/T07/T09); this page places them.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatPlatform
import AntiChatStorage
import Defaults
import Observation
import SwiftUI

@MainActor @Observable
final class PrivacyDataViewModel {
    /// R-091 AC1: the page's first paragraph.
    static let statementKey = CopyKey("privacy.statement")

    /// The rows under the statement, in settings-map §9 order (the registry holds the same order).
    static let rowOrder = [
        "offlineOnly", "networkActivity", "privacyLocation", "newChatsIncognito", "incognitoPersonalizationDefault",
        "importChats", "exportAll", "restoreBackup", "archivedChats", "archiveAll", "deleteAll", "autoArchiveDays",
        "crashReports", "exportLogs",
    ]

    @ObservationIgnored let database: AppDatabase?
    @ObservationIgnored let policy: NetworkPolicyStore
    @ObservationIgnored var now: () -> Date
    private(set) var groups: [NetworkActivityGroupSummary] = []

    init(database: AppDatabase?, policy: NetworkPolicyStore = .shared, now: @escaping () -> Date = Date.init) {
        self.database = database
        self.policy = policy
        self.now = now
        reload()
    }

    /// Re-reads `network_activity` and the gate's policy (on appear, on a policy change, on expanding a row).
    func reload() {
        let t = now()
        var entries: [NetworkActivityEntry] = []
        // No database (a preview, an unopened store): nothing to report, including the pre-window stamps.
        guard let database else {
            groups = NetworkActivitySummary.summarize(entries: [], now: t, offlineOnly: policy.offlineOnly,
                                                      enabled: { [policy] in policy.storedValue($0) })
            return
        }
        do {
            let rows = (try? NetworkActivityRecord.recent(database, since: t.addingTimeInterval(-NetworkActivitySummary.window))) ?? []
            entries = rows.map { NetworkActivityEntry(ts: $0.ts, category: $0.category, host: $0.host, bytes: $0.bytes, outcome: $0.outcome) }
        }
        let policy = policy
        groups = NetworkActivitySummary.summarize(entries: entries, now: t, offlineOnly: policy.offlineOnly,
                                                  enabled: { policy.storedValue($0) }, lastEver: { policy.lastUsed($0) })
    }

    static func groupLabel(_ g: NetworkActivityGroup) -> CopyKey { CopyKey("privacy.activity.group.\(g.rawValue)") }

    static func stateLabel(_ s: NetworkActivityGroupSummary.State) -> CopyKey { CopyKey("privacy.activity.\(s.rawValue)") }

    static func outcomeLabel(_ outcome: String) -> CopyKey {
        let known = ["ok", "httpError", "failed", "blocked"]
        return CopyKey("privacy.activity.outcome.\(known.contains(outcome) ? outcome : "failed")")
    }

    /// "Last used just now" / "Last used 5 minutes ago" / "Never" / "More than 7 days ago".
    static func lastUsedText(_ l: NetworkActivityGroupSummary.LastUsed, now: Date) -> String {
        switch l {
        case .never: return CopyKey("privacy.activity.never").string()
        case .beforeWindow: return CopyKey("privacy.activity.older").string()
        case let .at(ts):
            let time: String
            if now.timeIntervalSince(ts) < 60 {
                time = CopyKey("privacy.activity.justNow").string()
            } else {
                let f = RelativeDateTimeFormatter()
                f.unitsStyle = .full
                f.locale = Locale(identifier: "en_US_POSIX")
                time = f.localizedString(for: ts, relativeTo: now)
            }
            return CopyKey("privacy.activity.lastUsed").string(["time": time])
        }
    }
}

struct PrivacyDataView: View {
    @Bindable var model: SettingsModel
    let chats: ChatListService?
    @State private var privacy: PrivacyDataViewModel
    @Default(.autoArchiveDays) private var autoArchiveDays
    @Default(.crashReportMode) private var crashMode
    @Default(.newChatsIncognito) private var newChatsIncognito
    @Default(.incognitoPersonalizationDefault) private var incognitoPersonalization
    @Default(.searchUsesLocation) private var searchUsesLocation

    static let autoArchiveChoices = [0, 30, 90, 180]

    init(model: SettingsModel, chats: ChatListService?) {
        self.model = model
        self.chats = chats
        _privacy = State(initialValue: PrivacyDataViewModel(database: chats?.database))
    }

    var body: some View {
        Section {  // R-091 AC1: verbatim, selectable, the page's first paragraph
            // VQ (S-21 Privacy, M10): the rows' callout size, not body — the intro was the largest text on the page.
            Text(PrivacyDataViewModel.statementKey)
                .typeStyle(.callout)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset (text edges line up)
                .probeID("privacy.statement")
        }
        Section {  // M2.T03 + M8.T08 step 3
            OfflineOnlyRow()
            NetworkActivityList(model: privacy)
            SettingsItem("privacyLocation", description: CopyKey(searchUsesLocation ? "privacy.location.on" : "privacy.location")) {
                Button { model.open(.tools, row: "searchUsesLocation") } label: { Text(CopyKey("privacy.location.change")) }
                    .probeID("settings.control.privacyLocation")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkPolicyStore.didChange)) { _ in privacy.reload() }
        Section {  // step 5 (R-091 AC4, R-090)
            SettingsItem("newChatsIncognito") {
                Toggle(isOn: $newChatsIncognito) { Text(CopyKey("set.privacy.incognitoDefault")) }
                    .toggleStyle(.accessibleSwitch)
                    .labelsHidden()
                    .probeID("settings.control.newChatsIncognito")
            }
            SettingsItem("incognitoPersonalizationDefault", description: CopyKey("set.privacy.incognitoPersonalization.note")) {
                Picker(selection: $incognitoPersonalization) {
                    Text(CopyKey("incognito.personalized")).tag(IncognitoPersonalization.personalized.rawValue)
                    Text(CopyKey("incognito.unpersonalized")).tag(IncognitoPersonalization.unpersonalized.rawValue)
                } label: { Text(CopyKey("set.privacy.incognitoPersonalization")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.incognitoPersonalizationDefault")
            }
        }
        Section { dataRows }
        Section { chatRows }
        Section {  // M8.T09 (R-218 AC2/AC3, NFR-PR2); step 7 places them
            SettingsItem("crashReports") {
                Picker(selection: $crashMode) {
                    Text(CopyKey("crash.mode.ask")).tag(CrashReportMode.ask.rawValue)
                    Text(CopyKey("crash.mode.always")).tag(CrashReportMode.always.rawValue)
                    Text(CopyKey("crash.mode.never")).tag(CrashReportMode.never.rawValue)
                } label: { Text(CopyKey("set.privacy.crash")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.crashReports")
            }
            SettingsItem("exportLogs") {
                Button { model.showingExportLogs = true } label: { Text(CopyKey("set.privacy.exportLogs.button")) }
                    .probeID("settings.control.exportLogs")
            }
        }
        .sheet(isPresented: $model.showingArchived) {
            ArchivedChatsPage(chats: chats) { model.showingArchived = false }
        }
        .sheet(isPresented: $model.showingDeleteAll) {
            DeleteAllSheet(onDelete: {
                _ = try? chats?.deleteAll()
                model.showingDeleteAll = false
            }, onCancel: { model.showingDeleteAll = false })
        }
    }

    /// Import → Export all → Restore from backup.
    @ViewBuilder private var dataRows: some View {
        if FeatureFlag.importChats.isEnabled() {  // M8.T06 (R-092)
            SettingsItem("importChats") {
                Button { model.showingImport = true } label: { Text(CopyKey("set.privacy.import.button")) }
                    .probeID("settings.control.importChats")
                    .sheet(isPresented: $model.showingImport) {
                        ImportSheet(database: chats?.database) { model.showingImport = false }
                    }
            }
            .onAppear { if ImportRequest.shared.take() { model.showingImport = true } }
        }
        if FeatureFlag.exportAll.isEnabled() {  // M8.T07 (R-093)
            SettingsItem("exportAll") {
                Button { model.showingExport = true } label: { Text(CopyKey("set.privacy.exportAll")) }
                    .probeID("settings.control.exportAll")
                    .sheet(isPresented: $model.showingExport) {
                        ExportAllView(database: chats?.database) { model.showingExport = false }
                    }
            }
            .onAppear { if ExportRequest.shared.take() { model.showingExport = true } }
        }
        if let url = chats?.database.fileURL {  // M8.T01 (R-301 AC2); not for an in-memory database
            SettingsItem("restoreBackup") {
                Button { model.showingRestore = true } label: { Text(CopyKey("set.privacy.restore.button")) }
                    .probeID("settings.control.restoreBackup")
                    .sheet(isPresented: $model.showingRestore) {
                        RestoreBackupSheet(service: BackupService(databaseURL: url), relaunch: { AppRelaunch.relaunch() }) {
                            model.showingRestore = false
                        }
                    }
            }
        }
    }

    /// Archived chats → Archive all → Delete all (typed DELETE, step 6) → Auto-archive (M1.T22 step 5, R-011).
    @ViewBuilder private var chatRows: some View {
        SettingsItem("archivedChats") {
            Button { model.showingArchived = true } label: { Text(CopyKey("set.privacy.archived.manage")) }
                .probeID("settings.control.archivedChats")
        }
        SettingsItem("archiveAll") {
            Button { model.confirmingArchiveAll = true } label: { Text(CopyKey("set.privacy.archiveAll.button")) }
                .probeID("settings.control.archiveAll")
                .popover(isPresented: $model.confirmingArchiveAll, arrowEdge: .bottom) {
                    ArchiveAllConfirmation(onConfirm: {
                        _ = try? chats?.archiveAll()
                        model.confirmingArchiveAll = false
                    }, onCancel: { model.confirmingArchiveAll = false })
                }
        }
        SettingsItem("deleteAll") {
            Button(role: .destructive) { model.showingDeleteAll = true } label: {
                Text(CopyKey("set.privacy.deleteAll.button"))
            }
            .probeID("settings.control.deleteAll")
        }
        SettingsItem("autoArchiveDays", description: CopyKey("set.privacy.autoArchive.note")) {
            Picker(selection: $autoArchiveDays) {
                ForEach(Self.autoArchiveChoices, id: \.self) { d in
                    if d == 0 {
                        Text(CopyKey("set.privacy.autoArchive.never")).tag(0)
                    } else {
                        Text(CopyText(CopyKey("set.privacy.autoArchive.days"), ["days": "\(d)"])).tag(d)
                    }
                }
            } label: { Text(CopyKey("set.privacy.autoArchive")) }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.autoArchiveDays")
        }
    }
}

private struct ArchiveAllConfirmation: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("set.privacy.archiveAll.confirm"))
                .typeStyle(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("row.delete.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .probeID("archiveAll.cancel")
                Button(action: onConfirm) { Text(CopyKey("set.privacy.archiveAll.button")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("archiveAll.confirm")
            }
        }
        .padding(Spacing.space4)
        .frame(width: 300)
    }
}
