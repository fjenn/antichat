// M2.T07 (R-222 AC2): one pack × mode in Advanced — "Model for {pack} ({mode})", the current model's quant and context
// (read-only info), and a picker of the catalog's models for that slot, each with its FitPill. Too-large models are
// disabled unless "Allow loads above the memory budget" is on (NFR-R5). Model names appear here and only here
// (R-222 AC1: the default UI never shows them).
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct ModelOverrideRow: View {
    let pack: ModelPack
    let mode: ModelMode
    let current: SelectionSlot?
    let options: [ModelOverrideStore.Option]
    let overridden: String?
    let onPick: (String?) -> Void
    /// VQ: the catalog the names come from (published name, never the key).
    var catalog: ModelCatalog? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                Text(title)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: Spacing.space2)
                if options.isEmpty || current?.modelID == nil {
                    Text(CopyKey("set.cap.unavailable")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                } else {
                    let labels = ModelNames.pickerLabels(options.map { ($0.modelID, $0.quant) }) { ModelNames.name($0, catalog: catalog) }
                    Picker(selection: Binding(get: { overridden ?? "" }, set: { onPick($0.isEmpty ? nil : $0) })) {
                        Text(CopyKey("set.cap.recommended")).tag("")
                        ForEach(options) { o in
                            HStack {
                                Text(verbatim: labels[o.modelID] ?? o.modelID)
                                FitPill(fit: o.fit, identified: false)
                            }
                            .tag(o.modelID)
                            .disabled(o.disabled)
                            .selectionDisabled(o.disabled)
                        }
                    } label: { Text(title) }  // hidden; VoiceOver's name for the picker (M9.T03)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .accessibilityIdentifier("override.\(pack.rawValue).\(mode.rawValue)")
                }
            }
            if let id = current?.modelID {
                HStack(spacing: Spacing.space2) {
                    Text(verbatim: ModelNames.name(id, catalog: catalog)).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                    if let info = infoLine { Text(info).typeStyle(.footnote).foregroundStyle(Color.textSecondary) }
                    else if let quant = quantOnly { Text(verbatim: quant).typeStyle(.footnote).foregroundStyle(Color.textSecondary) }
                    if let fit = current?.fit { FitPill(fit: fit) }
                }
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .accessibilityIdentifier("override.info.\(pack.rawValue).\(mode.rawValue)")
            }
        }
        .padding(.vertical, 2)
    }

    /// "Model for {pack} ({mode})": the row's text and its picker's accessibility name.
    private var title: CopyText {
        CopyText(CopyKey("set.cap.override"), ["pack": Self.packName(pack), "mode": CopyKey("set.cap.mode.\(mode.rawValue)").string()])
    }

    /// "{quant} · {context} context" for models with a context window (chat); M2.T26 VQ: speech/image models have
    /// none, so they show the quant alone instead of "fp16 · — context".
    private var infoLine: CopyText? {
        guard let id = current?.modelID, let o = options.first(where: { $0.modelID == id }),
              let ctx = current?.ctx ?? o.ctx else { return nil }
        return CopyText(CopyKey("set.cap.modelInfo"), ["quant": ModelNames.precision(o.quant) ?? "—", "context": Self.tokens(ctx)])
    }

    private var quantOnly: String? {
        guard let id = current?.modelID, let o = options.first(where: { $0.modelID == id }) else { return nil }
        return ModelNames.precision(o.quant)
    }

    static func tokens(_ n: Int) -> String { n >= 1024 ? "\(n / 1024)K" : "\(n)" }

    static func packName(_ p: ModelPack) -> String {
        p == .chat ? CopyKey("set.cap.chat").string() : CopyKey("set.cap.pack.\(p.rawValue)").string()
    }
}
