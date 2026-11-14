// M8.T01 (R-301 AC1; S-25): a migration threw and MigrationRunner put the pre-migration backup back. The window
// says nothing was lost and offers [Restore backup] (RestoreBackupSheet), [Report a problem] (M8.T09, hidden until
// then) and Quit. BackupNoSpaceWindow: the pre-migration copy did not fit, so nothing was migrated.
import AntiChatDesign
import AntiChatStorage
import SwiftUI

struct MigrationFailedWindow: View {
    let code: String
    let databaseURL: URL
    let actions: LaunchBlockedActions
    @State private var restoring = false

    var body: some View {
        BlockingPanel(symbol: "exclamationmark.triangle", message: CopyText(CopyKey("storage.migrationFailed"))) {
            Button(action: { actions.quit() }) { Text(CopyKey("storage.quit.cta")) }
                .probeID("migrationFailed.quit")
            if let report = actions.reportProblem {
                Button(action: { report(code) }) { Text(CopyKey("set.about.report")) }
                    .probeID("migrationFailed.report")
            }
            Button(action: { restoring = true }) { Text(CopyKey("storage.restoreBackup.cta")) }
                .keyboardShortcut(.defaultAction)
                .probeID("migrationFailed.restore")
        }
        .sheet(isPresented: $restoring) {
            RestoreBackupSheet(service: BackupService(databaseURL: databaseURL), relaunch: { actions.relaunch() }) { restoring = false }
        }
        .probeID("migrationFailed.window")
    }
}

struct BackupNoSpaceWindow: View {
    let neededBytes: Int64
    let actions: LaunchBlockedActions

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", max(0.1, Double(bytes) / 1e9))
    }

    var body: some View {
        BlockingPanel(symbol: "externaldrive.badge.exclamationmark",
                      message: CopyText(CopyKey("storage.backupNoSpace"), ["gb": Self.gigabytes(neededBytes)])) {
            Button(action: { actions.quit() }) { Text(CopyKey("storage.quit.cta")) }
                .probeID("backupNoSpace.quit")
            Button(action: { actions.relaunch() }) { Text(CopyKey("storage.tryAgain.cta")) }
                .keyboardShortcut(.defaultAction)
                .probeID("backupNoSpace.retry")
        }
        .probeID("backupNoSpace.window")
    }
}
