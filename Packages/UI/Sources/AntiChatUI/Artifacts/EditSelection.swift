// M6.T13 step 4 (R-016 AC4): "Edit selection" on a doc / code artifact. Selecting text in the panel's text body shows
// [panel.editSelection]; on an artifact it opens this popover — the selection quoted, a field
// (`panel.editSelection.placeholder`) — and Return sends ArtifactEditService's turn ("Edit only this part of <title>:
// «selection» — instruction: …"); the reply becomes version n + 1 and replaces the panel content (the picker keeps the
// old one). On a file that is not an artifact (an attached PDF) the button prefills the composer with the quote (M4.T11).
import AntiChatDesign
import SwiftUI

struct EditSelectionPopover: View {
    @Bindable var model: SidePanelModel
    @State private var instruction = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(verbatim: "«\(model.selection.count > 160 ? String(model.selection.prefix(160)) + "…" : model.selection)»")
                .typeStyle(.footnote).foregroundStyle(Color.textSecondary).lineLimit(3)
                .accessibilityIdentifier("editSelectionQuote")
            TextField(text: $instruction, prompt: Text(CopyKey("panel.editSelection.placeholder"))) {
                Text(CopyKey("panel.editSelection"))
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(submit)
            .accessibilityIdentifier("editSelectionField")
            HStack {
                Spacer()
                Button { model.editingSelection = false } label: { Text(CopyKey("msg.edit.cancel")) }
                    .accessibilityIdentifier("msg.edit.cancel")
                    .keyboardShortcut(.cancelAction)
                Button(action: submit) { Text(CopyKey("panel.editSelection")) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("editSelectionSubmit")
            }
        }
        .padding(Spacing.space3)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private func submit() {
        guard !instruction.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.submitEditSelection(instruction: instruction)
        instruction = ""
    }
}
