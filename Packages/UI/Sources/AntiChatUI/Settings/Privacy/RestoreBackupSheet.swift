// M8.T01 (R-301 AC2; S-21 §9 Privacy & Data "Restore from backup"): the backups (date, kind, size, chat count read
// read-only), [Restore] → confirm → the restore is staged and the app relaunches; MigrationRunner saves the current
// data as `pre-restore-<ts>.sqlite` and swaps the files before any connection opens.
import AntiChatDesign
import AntiChatStorage
import SwiftUI

struct RestoreBackupSheet: View {
    let service: BackupService
    let relaunch: @MainActor () -> Void
    let onClose: () -> Void
    @State private var rows: [Row] = []
    @State private var confirming: Row?

    struct Row: Identifiable, Equatable {
        var backup: BackupService.Backup
        var chats: Int?
        var id: String { backup.id }
    }

    static func kindKey(_ k: BackupService.Kind) -> CopyKey {
        switch k {
        case .daily: CopyKey("backup.kind.daily")
        case .preUpdate: CopyKey("backup.kind.preUpdate")
        case .preRestore: CopyKey("backup.kind.preRestore")
        }
    }

    static func load(_ service: BackupService) -> [Row] {
        ((try? service.list()) ?? []).map { Row(backup: $0, chats: BackupService.chatCount($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("backup.restore.title")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            if rows.isEmpty {
                Text(CopyKey("backup.restore.empty")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .probeID("restore.empty")
            } else {
                List(rows) { row in
                    HStack(spacing: Spacing.space3) {
                        VStack(alignment: .leading, spacing: Spacing.space1) {
                            Text(row.backup.date.formatted(date: .abbreviated, time: row.backup.kind == .daily ? .omitted : .shortened))
                                .typeStyle(.body)
                            HStack(spacing: Spacing.space2) {
                                Text(Self.kindKey(row.backup.kind))
                                Text(ByteCountFormatter.string(fromByteCount: row.backup.bytes, countStyle: .file))
                                if let n = row.chats { Text(CopyText(CopyKey("backup.restore.chats"), ["count": "\(n)"])) }
                            }
                            .typeStyle(.caption)
                            .foregroundStyle(Color.textSecondary)
                        }
                        Spacer()
                        Button(action: { confirming = row }) { Text(CopyKey("backup.restore.cta")) }
                            .probeID("restore.row.\(row.id)")
                    }
                }
                .frame(minHeight: 220)
                .probeID("restore.list")
            }
            Text(CopyKey("backup.restore.note")).typeStyle(.caption).foregroundStyle(Color.textSecondary)
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("backup.restore.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .probeID("restore.cancel")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 480)
        .onAppear { rows = Self.load(service) }
        .alert(item: $confirming) { row in
            Alert(title: Text(CopyText(CopyKey("backup.restore.confirm"),
                                       ["date": row.backup.date.formatted(date: .abbreviated, time: .shortened)])),
                  primaryButton: .destructive(Text(CopyKey("backup.restore.cta"))) {
                      if (try? service.stageRestore(row.backup)) != nil { relaunch() }
                  },
                  secondaryButton: .cancel(Text(CopyKey("backup.restore.cancel"))))
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("restore.sheet")
    }
}
