// M6.T20 (R-276 AC2): what `edit_office_file` shows when File tools is not installed (or Run code is off): the
// download (`sandbox.notInstalled` with the catalog size, [Install] → RuntimeInstaller with progress) and the
// re-creation path ([`edit.recreate`] regenerates the reply with OfficeEditIntent.recreateSteering → create_* tools),
// labelled `edit.formattingMayChange`. Nothing is edited here; the original attachment is never touched.
import AntiChatDesign
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import SwiftUI

enum OfficeEditActivity {
    static func isEdit(_ a: ToolActivity) -> Bool { a.kind == .tool && a.tool == EditOfficeFileTool.name }
    static func offer(_ a: ToolActivity) -> OfficeEditOffer? { a.result.flatMap(OfficeEditOffer.parse) }
}

struct OfficeEditOfferCard: View {
    let offer: OfficeEditOffer
    let database: AppDatabase?
    let onRecreate: (() -> Void)?
    @State private var model: FileToolsSettingsModel?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .top, spacing: Spacing.space2) {
                Image(systemName: "doc.badge.gearshape").foregroundStyle(Color.textSecondary)
                Text(model?.installLabel ?? CopyKey("sandbox.notInstalled").string(["size": "85 MB"]))
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("officeEditOfferText")
            }
            if let model, model.progress != nil {
                ProgressView(value: model.fraction).progressViewStyle(.linear)
                    .accessibilityIdentifier("officeEditOfferProgress")
            }
            HStack(spacing: Spacing.space2) {
                Button(action: { model?.install() }) { Text(CopyText(CopyKey("install.cta"))) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model?.runtime == nil || model?.progress != nil || model?.installed != nil)
                    .accessibilityIdentifier("officeEditOfferInstall")
                    .probeID("officeEditOfferInstall")
                if let onRecreate {
                    Button(action: onRecreate) { Text(CopyText(CopyKey("edit.recreate"))) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("officeEditOfferRecreate")
                        .probeID("officeEditOfferRecreate")
                }
            }
            .controlSize(.regular)
            Text(CopyText(CopyKey("edit.formattingMayChange")))
                .typeStyle(.caption)
                .foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("officeEditOfferWarning")
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.borderControl, lineWidth: Stroke.control))
        .padding(.leading, Spacing.space5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("officeEditOffer")
        .probeID("officeEditOffer")
        .task { if model == nil { model = FileToolsSettingsModel.shared(database: database) } }
    }
}
