// M2.T10 step 7 (NFR-S5): a pack row whose model failed the load-time check shows `model.corrupt` ("This model file is
// damaged.") and [Re-download ({size})] — {size} = only the bad files (`Repair.redownloadBytes`). The action runs
// `Repair.run` (re-hash, re-fetch the bad blobs, rebuild the view).
import AntiChatDesign
import SwiftUI

struct RepairButton: View {
    let bytes: Int64
    let action: () -> Void

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.danger)
            Text(CopyKey("model.corrupt")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
            Spacer(minLength: Spacing.space2)
            Button(action: action) {
                Text(CopyText(CopyKey("model.corrupt.redownload"), ["size": DownloadAskSheet.size(bytes)]))
            }
            .probeID("repair.redownload")
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("repairButton")
    }
}
