// M2.T09 steps 1–2 (R-204 AC1, AC6; NFR-D2): the two download sheets.
//   DiskShortSheet: `download.diskFull` "Needs {gb} GB more free space." + [Open Storage] (Settings › Storage).
//   DownloadAskSheet: `download.expensiveAsk` "This is {size}. You're on a personal hotspot. Download anyway?"
//   + [Download] [Later] (VISION §2.19).
import AntiChatDesign
import SwiftUI

struct DiskShortSheet: View {
    let gbNeeded: Int
    let onOpenStorage: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Label { Text(CopyText(CopyKey("download.diskFull"), ["gb": "\(gbNeeded)"])).typeStyle(.headline) } icon: {
                Image(systemName: "externaldrive.badge.exclamationmark")
            }
            .foregroundStyle(Color.textPrimary)
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("download.diskFull.close")) }
                    .probeID("diskShort.close")
                Button(action: onOpenStorage) { Text(CopyKey("download.diskFull.openStorage")) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.primary)
                    .probeID("diskShort.openStorage")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 400)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("diskShortSheet")
    }
}

struct DownloadAskSheet: View {
    let bytes: Int64
    let onDownload: () -> Void
    let onLater: () -> Void

    /// "14 GB", "1.2 GB" (decimal, as Finder).
    static func size(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .decimal
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Label { Text(CopyText(CopyKey("download.expensiveAsk"), ["size": Self.size(bytes)])).typeStyle(.headline) } icon: {
                Image(systemName: "personalhotspot")
            }
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onLater) { Text(CopyKey("download.expensiveAsk.later")) }
                    .probeID("expensiveAsk.later")
                Button(action: onDownload) { Text(CopyKey("download.expensiveAsk.download")) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.primary)
                    .probeID("expensiveAsk.download")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 420)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("downloadAskSheet")
    }
}

/// R-204 AC5: after three connection failures in a row, "Download paused — check your connection" + [Retry]
/// (`DownloadPolicy.retryNow()`), in the sidebar footer above the StatusPill.
struct DownloadPausedNotice: View {
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "wifi.exclamationmark")
            Text(CopyKey("download.pausedConnection")).typeStyle(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onRetry) { Text(CopyKey("msg.retry")).typeStyle(.caption) }
                .buttonStyle(.link)
                .probeID("download.retry")
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space1)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("downloadPausedNotice")
    }
}
