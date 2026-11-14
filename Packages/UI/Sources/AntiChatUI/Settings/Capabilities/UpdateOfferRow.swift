// M2.T11 step 2 (R-294 AC4, R-220 AC2): an update that is not silent — over +2 GB, "Update models automatically" off,
// or short on disk — shows here: "A better {pack} model is available ({size}). Update now?" [Update] [Later].
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct UpdateOfferRow: View {
    let offer: UpdateCandidate
    let onUpdate: () -> Void
    let onLater: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Text(CopyText(CopyKey("model.updateAsk"), ["pack": ModelOverrideRow.packName(offer.pack), "size": DownloadAskSheet.size(offer.extraBytes)]))
                .typeStyle(.callout)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.space2)
            Button(action: onLater) { Text(CopyKey("model.update.later")) }
                .accessibilityIdentifier("updateOffer.later")
            Button(action: onUpdate) { Text(CopyKey("model.update.now")) }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("updateOffer.update")
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("updateOffer.\(offer.slot)")
    }
}

/// Capabilities' update area: pending notices and offer rows (nothing when there is neither).
struct ModelUpdateRows: View {
    let status: ModelUpdateStatus

    var body: some View {
        if !status.notices.isEmpty || !status.offers.isEmpty {
            Section {
                ForEach(Array(status.notices.enumerated()), id: \.offset) { _, n in
                    ModelUpdateNotice(notice: n) { status.dismiss(n) }
                }
                ForEach(status.offers, id: \.slot) { o in
                    UpdateOfferRow(offer: o,
                                   onUpdate: { Task { await ModelUpdatesLaunch.service?.accept(slot: o.slot) } },
                                   onLater: { Task { await ModelUpdatesLaunch.service?.later(slot: o.slot) } })
                }
            }
        }
    }
}
