// Delete all chats (M1.T22 step 5; R-011 AC4 "Delete all requires typing DELETE"; copy `deleteAll.type`):
// the Delete button stays disabled until the field holds exactly DELETE.
import AntiChatDesign
import SwiftUI

struct DeleteAllSheet: View {
    let onDelete: () -> Void
    let onCancel: () -> Void
    @State private var typed = ""

    static let word = "DELETE"
    static func isConfirmed(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces) == word }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("set.privacy.deleteAll")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            Text(CopyKey("set.privacy.deleteAll.confirm"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $typed) { Text(CopyKey("deleteAll.type")) }
                .textFieldStyle(.roundedBorder)
                .probeID("deleteAll.field")
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("row.delete.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .probeID("deleteAll.cancel")
                Button(role: .destructive, action: onDelete) { Text(CopyKey("set.privacy.deleteAll.button")) }
                    .tint(Color.danger)
                    .disabled(!Self.isConfirmed(typed))
                    .probeID("deleteAll.confirm")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 420)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("deleteAll.sheet")
    }
}
