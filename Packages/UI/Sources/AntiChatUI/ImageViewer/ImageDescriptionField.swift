// M9.T02 step 5 (NFR-A5, A-M9-T02a): the viewer's "Description": the vision model's description of the picture,
// written after it is shown (never blocking), editable; an edit is saved when the field is submitted or loses focus
// and the model never replaces it. VoiceOver reads the same text as the picture's label.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct ImageDescriptionField: View {
    let path: String
    @State private var text = ""
    @State private var loaded = ""
    @State private var writing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(spacing: Spacing.space2) {
                Text(CopyKey("viewer.description")).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                if writing {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                    Text(CopyKey("viewer.description.writing")).typeStyle(.caption).foregroundStyle(Color.textTertiary)
                }
            }
            TextField(text: $text, axis: .vertical) { Text(CopyKey("viewer.description.placeholder")) }
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, now in if !now { save() } }
                .accessibilityLabel(Text(CopyKey("viewer.description")))
                .accessibilityIdentifier("imageViewer.description")
        }
        .task(id: path) { await load() }
        .onDisappear(perform: save)
    }

    private func load() async {
        guard let service = ImageDescriptions.service else { return }
        if let d = await service.current(path) { text = d.text; loaded = d.text; return }
        writing = true
        let d = await service.ensure(path)
        writing = false
        if let d, text.isEmpty || text == loaded { text = d.text; loaded = d.text }
    }

    private func save() {
        guard text != loaded, let service = ImageDescriptions.service else { return }
        loaded = text
        let (path, text) = (path, text)
        Task { await service.setUser(path, text: text) }
    }
}

/// The picture's spoken label: "Generated image: <description>" (the prompt until the description is written).
struct GeneratedImageLabel: ViewModifier {
    let path: String?
    let fallback: String?
    @State private var description: String?

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(Text(CopyText(CopyKey("a11y.generatedImage"), ["description": description ?? fallback ?? ""])))
            .accessibilityAddTraits(.isImage)
            .task(id: path) {
                guard let path, let service = ImageDescriptions.service else { return }
                description = await service.ensure(path)?.text
            }
    }
}

extension View {
    func generatedImageLabel(path: String?, fallback: String?) -> some View {
        modifier(GeneratedImageLabel(path: path, fallback: fallback))
    }
}
