// M8.T04 steps 2 + 8 (R-064 AC1/AC4; S-20): the Projects page (empty state `projects.empty` + New project), the
// New project sheet (name ≤ 60, 24-icon picker) and the delete dialog (Delete chats too · Keep chats · Cancel).
// Layout reference: osaurus@2922745 Views/Chat/ProjectDetailView.swift (no code copied).
import AntiChatDesign
import AntiChatKnowledge
import SwiftUI

struct ProjectsListView: View {
    let model: ProjectsModel
    let onOpen: (String) -> Void
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack {
                Text(CopyKey("side.projects")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
                Spacer()
                Button { creating = true } label: { Label { Text(CopyKey("project.new")) } icon: { Image(systemName: "plus") } }
                    .buttonStyle(PrimaryButtonStyle())
                    .probeID("projects.new")
            }
            if model.projects.isEmpty {
                VStack(spacing: Spacing.space3) {
                    Image(systemName: "folder").font(.system(size: 32)).foregroundStyle(Color.textTertiary)
                    Text(CopyKey("projects.empty")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .probeID("projects.empty")
            } else {
                List(model.projects) { p in
                    Button { onOpen(p.id) } label: {
                        HStack(spacing: Spacing.space3) {
                            Image(systemName: p.icon).frame(width: 20).foregroundStyle(Color.textSecondary)
                            Text(verbatim: p.name).typeStyle(.body).foregroundStyle(Color.textPrimary)
                            Spacer()
                            Text(verbatim: "\(p.chatCount)").typeStyle(.caption).foregroundStyle(Color.textTertiary).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .probeID("projects.row.\(p.id)")
                }
                .listStyle(.inset)
            }
        }
        // M9.T08 R6: the same page frame as Library and Chats (title3 header on the leading edge, full width) — the
        // centred 760 pt column with a title2 header read as a different kind of page.
        .padding(Spacing.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.surfaceCanvas)
        .sheet(isPresented: $creating) {
            NewProjectSheet { name, icon in
                creating = false
                if let p = model.create(name: name, icon: icon) { onOpen(p.id) }
            } onCancel: { creating = false }
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("projectsList")
    }
}

struct NewProjectSheet: View {
    let onCreate: (String, String) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @State private var icon = "folder"
    @FocusState private var focused: Bool

    static func valid(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !n.isEmpty && n.count <= Project.maxName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("project.new")).typeStyle(.title3)
            TextField(text: $name) { Text(CopyKey("project.new.name")) }
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if Self.valid(name) { onCreate(name, icon) } }
                .probeID("project.new.name")
            IconPicker(selection: $icon)
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("project.cancel")) }.keyboardShortcut(.cancelAction)
                Button { onCreate(name, icon) } label: { Text(CopyKey("project.new.create")) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!Self.valid(name))
                    .probeID("project.new.create")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 420)
        .onAppear { focused = true }
    }
}

struct IconPicker: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: Spacing.space2), count: 8), spacing: Spacing.space2) {
            ForEach(Project.icons, id: \.self) { s in
                Button { selection = s } label: {
                    Image(systemName: s)
                        .frame(width: 32, height: 32)
                        .foregroundStyle(selection == s ? Color.textPrimary : Color.textSecondary)
                        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(selection == s ? Color.surfaceSelected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: s))
                .accessibilityAddTraits(selection == s ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("project.iconPicker")
    }
}

struct DeleteProjectDialog: View {
    let name: String
    let chatCount: Int
    let onDeleteChats: () -> Void
    let onKeepChats: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyText(CopyKey("project.delete.title"), ["name": name])).typeStyle(.title3)
            Text(CopyText(CopyKey("project.delete.body"), ["count": "\(chatCount)"])).typeStyle(.body)
                .foregroundStyle(Color.textSecondary)
            HStack {
                Button(action: onCancel) { Text(CopyKey("project.cancel")) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(action: onKeepChats) { Text(CopyKey("project.delete.keep")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("project.delete.keep")
                Button(role: .destructive, action: onDeleteChats) { Text(CopyKey("project.delete.chats")) }
                    .probeID("project.delete.chats")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 440)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("project.deleteDialog")
    }
}
