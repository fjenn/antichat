// M8.T04 step 3 (R-064 AC1–AC3; S-20): the project page — header (icon, inline rename, ⋯ Rename / Change icon /
// Delete), New chat in project, then Chats, Files (drop zone, Add files…, Link a folder…, per file name · size ·
// pages · index state with the real %), Instructions (autosave 500 ms; "Changes apply to new chats in this project.")
// and the Project-only memory switch (default off = global memory). Layout reference: osaurus@2922745
// Views/Chat/ProjectDetailView.swift + ProjectInspectorPanel.swift (no code copied).
import AntiChatDesign
import AntiChatKnowledge
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProjectPageView: View {
    @State private var model: ProjectPageModel
    let projects: ProjectsModel
    let onNewChat: (String) -> Void
    let onOpenChat: (String) -> Void
    let onDeleted: () -> Void
    @State private var renaming = false
    @State private var draftName = ""
    @State private var pickingIcon = false
    @State private var deleting = false

    init(projectID: String, projects: ProjectsModel, onNewChat: @escaping (String) -> Void,
         onOpenChat: @escaping (String) -> Void, onDeleted: @escaping () -> Void) {
        _model = State(initialValue: ProjectPageModel(projectID: projectID, database: projects.database))
        self.projects = projects
        self.onNewChat = onNewChat
        self.onOpenChat = onOpenChat
        self.onDeleted = onDeleted
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space5) {
                header
                Button { onNewChat(model.projectID) } label: {
                    Label { Text(CopyKey("project.newChat")) } icon: { Image(systemName: "square.and.pencil") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.large)
                .probeID("project.newChat")
                chatsSection
                ProjectFilesView(model: model)
                instructionsSection
                memorySection
            }
            .padding(Spacing.space6)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.surfaceCanvas)
        .onDisappear { model.flushInstructions() }
        .sheet(isPresented: $deleting) {
            DeleteProjectDialog(name: model.project?.name ?? "", chatCount: model.chats.count,
                                onDeleteChats: { finishDelete(keepChats: false) },
                                onKeepChats: { finishDelete(keepChats: true) },
                                onCancel: { deleting = false })
        }
        .probeID("projectPage")
    }

    private func finishDelete(keepChats: Bool) {
        deleting = false
        projects.delete(model.projectID, keepChats: keepChats)
        onDeleted()
    }

    private var header: some View {
        HStack(spacing: Spacing.space3) {
            Button { pickingIcon = true } label: {
                Image(systemName: model.project?.icon ?? "folder").font(.system(size: 22)).foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(CopyKey("project.changeIcon")))  // M9.T01
            .popover(isPresented: $pickingIcon) {
                IconPicker(selection: Binding(get: { model.project?.icon ?? "folder" },
                                              set: { model.setIcon($0); pickingIcon = false }))
                    .padding(Spacing.space3)
                    .popoverSurface()
            }
            if renaming {
                TextField(text: $draftName) { Text(CopyKey("project.new.name")) }
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.rename(draftName); renaming = false }
                    .onExitCommand { renaming = false }
                    .frame(maxWidth: 360)
                    .probeID("project.renameField")
            } else {
                Text(verbatim: model.project?.name ?? "").typeStyle(.title2).foregroundStyle(Color.textPrimary)
                    .onTapGesture(count: 2) { startRename() }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: Text(CopyKey("project.rename"))) { startRename() }  // M9.T01
            }
            Spacer()
            Menu {
                Button { startRename() } label: { Text(CopyKey("project.rename")) }
                    .accessibilityIdentifier("project.rename")
                Button { pickingIcon = true } label: { Text(CopyKey("project.changeIcon")) }
                    .accessibilityIdentifier("project.changeIcon")
                Divider()
                Button(role: .destructive) { deleting = true } label: { Text(CopyKey("project.delete")) }
                    .probeID("project.menu.delete")
            } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(Text(CopyKey("chat.more")))  // M9.T01: "More"
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("project.menu")
        }
    }

    private func startRename() {
        draftName = model.project?.name ?? ""
        renaming = true
    }

    private var chatsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("project.section.chats")).typeStyle(.headline).foregroundStyle(Color.textPrimary)
            if model.chats.isEmpty {
                Text(CopyText(CopyKey("empty.project.headline"), ["project": model.project?.name ?? ""]))
                    .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .probeID("project.chats.empty")
            } else {
                ForEach(model.chats) { c in
                    Button { onOpenChat(c.id) } label: {
                        HStack {
                            Image(systemName: "bubble.left").foregroundStyle(Color.textTertiary)
                            Text(verbatim: c.title.isEmpty ? CopyKey("side.untitled").string() : c.title)
                                .typeStyle(.body).foregroundStyle(Color.textPrimary).lineLimit(1)
                            Spacer()
                            Text(c.updatedAt, style: .date).typeStyle(.caption).foregroundStyle(Color.textTertiary)
                        }
                        .padding(.vertical, Spacing.space1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .probeID("project.chat.\(c.id)")
                }
            }
        }
    }

    private var instructionsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("project.section.instructions")).typeStyle(.headline).foregroundStyle(Color.textPrimary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.instructions)
                    .font(.body)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.space2)
                    .background(RoundedRectangle(cornerRadius: Radius.md).fill(Color.surfaceSunken))
                    .onChange(of: model.instructions) { _, _ in model.instructionsChanged() }
                    .probeID("project.instructions")
                if model.instructions.isEmpty {
                    Text(CopyKey("project.instructions.placeholder")).typeStyle(.body).foregroundStyle(Color.textTertiary)
                        .padding(Spacing.space3).allowsHitTesting(false)
                }
            }
            Text(CopyKey("project.instructions.note")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
        }
    }

    private var memorySection: some View {
        Toggle(isOn: Binding(get: { model.projectOnlyMemory }, set: { model.projectOnlyMemory = $0 })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CopyKey("project.memory.own")).typeStyle(.body)
                Text(CopyKey("project.memory.own.note")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
            }
        }
        .toggleStyle(.accessibleSwitch)
        .probeID("project.memoryOwn")
    }
}

struct ProjectFilesView: View {
    @Bindable var model: ProjectPageModel
    @State private var targeted = false

    static func stateText(_ f: ProjectFile) -> CopyText {
        switch f.indexState {
        case .pending: CopyText(CopyKey("project.file.pending"))
        case .indexing: CopyText(CopyKey("project.file.indexing"), ["percent": "\(Int((f.progress * 100).rounded(.down)))"])
        case .ready: CopyText(CopyKey("project.file.ready"))
        case .error: CopyText(CopyKey("project.file.error"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack {
                Text(CopyKey("project.section.files")).typeStyle(.headline).foregroundStyle(Color.textPrimary)
                Spacer()
                Button { pickFiles() } label: { Text(CopyKey("project.files.add")) }.probeID("project.files.add")
                Button { pickFolder() } label: { Text(CopyKey("project.files.link")) }.probeID("project.files.link")
            }
            if model.limitHit {
                Text(CopyKey("project.files.limit")).typeStyle(.footnote).foregroundStyle(Color.danger)
                    .probeID("project.files.limit")
            }
            if model.folderMissing {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.danger)
                    Text(CopyKey("project.folder.missing")).typeStyle(.footnote)
                    Button { pickFolder() } label: { Text(CopyKey("project.folder.locate")) }.buttonStyle(.link)
                }
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .probeID("project.folder.missing")
            }
            ForEach(model.files) { f in
                HStack(spacing: Spacing.space2) {
                    Image(systemName: f.origin == .linked ? "link" : "doc").foregroundStyle(Color.textTertiary)
                    Text(verbatim: f.relPath ?? f.displayName).typeStyle(.callout).lineLimit(1)
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                        .typeStyle(.caption).foregroundStyle(Color.textTertiary)
                    if let p = f.pages {
                        Text(CopyText(CopyKey("project.file.pages"), ["count": "\(p)"])).typeStyle(.caption).foregroundStyle(Color.textTertiary)
                    }
                    Spacer()
                    if f.indexState == .indexing { ProgressView(value: f.progress).frame(width: 60).controlSize(.small) }
                    Text(Self.stateText(f)).typeStyle(.caption)
                        .foregroundStyle(f.indexState == .error ? Color.danger : Color.textSecondary)
                    if f.origin == .copied {
                        Button { model.remove(f.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                            .accessibilityLabel(Text(CopyKey("project.file.remove")))
                    }
                }
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .probeID("project.file.\(f.id)")
            }
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(targeted ? Color.accentColor : Color.borderSubtle)
                .frame(height: 56)
                .overlay { Text(CopyKey("project.files.drop")).typeStyle(.callout).foregroundStyle(Color.textSecondary) }
                .dropDestination(for: URL.self) { urls, _ in
                    model.add(urls.filter(\.isFileURL))
                    return true
                } isTargeted: { targeted = $0 }
                .probeID("project.files.dropZone")
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { model.link(url) }
    }
}
