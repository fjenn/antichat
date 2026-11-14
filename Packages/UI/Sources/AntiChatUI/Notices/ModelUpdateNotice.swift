// M2.T11 (R-294 AC1/AC3, step 6): the update notices — `model.upgraded` "{pack} got an upgrade",
// `model.updateReverted` and `model.revoked` — shown as a dismissable line in Settings › Capabilities (and wherever the
// app's notice area hosts it). {pack} is the pack's display name, never a model name (R-222 AC1).
import AntiChatDesign
import AntiChatPlatform
import Observation
import SwiftUI

/// The update service's notices and offer rows on the main actor.
@MainActor @Observable
public final class ModelUpdateStatus {
    public var notices: [ModelUpdateService.Notice] = []
    public var offers: [UpdateCandidate] = []
    public init() {}

    public func dismiss(_ n: ModelUpdateService.Notice) { notices.removeAll { $0 == n } }
}

struct ModelUpdateNotice: View {
    let notice: ModelUpdateService.Notice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: notice.key == "model.upgraded" ? "arrow.up.circle" : "arrow.uturn.backward.circle")
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            Text(Self.text(notice)).typeStyle(.callout).foregroundStyle(Color.textPrimary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.space2)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(CopyKey("memory.dismiss")))
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityIdentifier("modelUpdateNotice.\(notice.key)")
    }

    static func text(_ n: ModelUpdateService.Notice) -> CopyText {
        var args = n.args
        if let p = args["pack"].flatMap(ModelPack.init(rawValue:)) { args["pack"] = ModelOverrideRow.packName(p) }
        return CopyText(CopyKey(n.key), args)
    }
}
