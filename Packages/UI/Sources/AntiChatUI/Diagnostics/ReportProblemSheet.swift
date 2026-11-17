// M8.T09 step 6 (R-218 AC4; S-24): Report a problem — from Help › Report a Problem…, 👎 › Report a problem and
// About & Help. Fields: What happened (required), Steps (optional), the read-only details block (app version + build,
// macOS, chip, RAM, tier, speed class, models, catalog), "Attach the log bundle (no chats)" (on), "Include this
// chat's text" (off; only when opened from a message). [Open on GitHub] / [Email instead] hand off to the browser /
// Mail (ReportProblemComposer); AntiChat sends nothing itself. Replaces the M1.T10 shell.
// Attachments (owner 2026-11-16): [Attach…] (file picker), a drop anywhere on the sheet, or ⌘V of a picture / copied
// files add up to 5 items, 15 MB together (ReportAttachments); each shows as a chip with a thumbnail and a remove
// button. Mail gets them as attachments. An issue URL cannot carry files, so after [Open on GitHub] (and after
// [Copy Report]) they are selected in Finder, next to the log bundle, to drag into the issue.
import AntiChatDesign
import AntiChatPlatform
import AntiChatStorage
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ReportProblemSheet: View {
    /// The chat's text when opened from a message (👎); nil elsewhere.
    var chatText: String? = nil
    var database: AppDatabase? = nil
    let onClose: () -> Void

    @State private var details = ""
    @State private var steps = ""
    @State private var attachLogs = true
    @State private var includeChat = false
    @State private var systemBlock = ""
    @State private var note: CopyText?
    @State private var attachments: [ReportAttachment]
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?
    /// Snapshot tests: a fixed details block instead of this Mac's live system report.
    private let fixedSystemBlock: String?

    init(chatText: String? = nil, database: AppDatabase? = nil, attachments: [ReportAttachment] = [],
         systemBlock: String? = nil, onClose: @escaping () -> Void) {
        self.chatText = chatText
        self.database = database
        self.onClose = onClose
        fixedSystemBlock = systemBlock
        _attachments = State(initialValue: attachments)
        _systemBlock = State(initialValue: systemBlock ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("report.title"))
                .typeStyle(.title3)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("report.title")
            Text(CopyKey("report.body"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            field($details, CopyKey("report.placeholder"), lines: 3...6).accessibilityIdentifier("report.details")
            field($steps, CopyKey("report.steps"), lines: 2...4).accessibilityIdentifier("report.steps")
            Text(CopyKey("report.details")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
            Text(verbatim: systemBlock)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.space2)
                .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .accessibilityIdentifier("report.system")
            Toggle(isOn: $attachLogs) { Text(CopyKey("report.attachLogs")) }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("report.attachLogs")
            if chatText != nil {
                Toggle(isOn: $includeChat) { Text(CopyKey("report.includeChat")) }
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("report.includeChat")
            }
            attachmentsBlock
            if let note {
                Text(note).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("report.note")
            }
            HStack {
                Button(action: onClose) { Text(CopyKey("report.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("report.cancel")
                Spacer()
                if DiagnosticsCenter.shared.endpoints != nil {
                    Button { send(email: true) } label: { Text(CopyKey("report.email")) }
                        .disabled(!ready)
                        .accessibilityIdentifier("report.email")
                    Button { send(email: false) } label: { Text(CopyKey("report.github")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!ready)
                        .accessibilityIdentifier("report.github")
                } else {
                    // Release build without real endpoints yet (M10): no broken mailto / issue URL, the text to the clipboard.
                    Button {
                        Task { @MainActor in
                            let r = await report()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ReportProblemComposer.body(r), forType: .string)
                            note = CopyText(CopyKey(r.attachments.isEmpty ? "report.copiedOnly" : "report.attach.copied"))
                            reveal(r)
                        }
                    } label: { Text(CopyKey("report.copy")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!ready)
                        .accessibilityIdentifier("report.copy")
                }
            }
        }
        .padding(Spacing.space5)
        .frame(width: 480)
        .background(Color.surfaceCanvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reportSheet")
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in attach(await PasteHandler.fileURLs(from: providers)) }
            return true
        }
        .overlay { if dropTargeted { dropHint } }
        .onAppear(perform: watchPaste)
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
        .task {
            guard fixedSystemBlock == nil else { return }
            let db = database
            let center = DiagnosticsCenter.shared
            systemBlock = await center.liveSystemReport(database: db).text()
        }
    }

    private var ready: Bool { !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !systemBlock.isEmpty }

    private func field(_ text: Binding<String>, _ placeholder: CopyKey, lines: ClosedRange<Int>) -> some View {
        TextField(text: text, axis: .vertical) { Text(placeholder) }
            .textFieldStyle(.plain)
            .typeStyle(.body)
            .lineLimit(lines)
            .padding(Spacing.space2)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }

    // MARK: Attachments

    @ViewBuilder private var attachmentsBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                Button(action: pickFiles) { Label { Text(CopyKey("report.attach")) } icon: { Image(systemName: "paperclip") } }
                    .disabled(attachments.count >= ReportAttachments.maxCount)
                    .accessibilityIdentifier("report.attach")
                Text(CopyText(CopyKey("report.attach.hint"), Self.limitArgs))
                    .typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !attachments.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.space2), GridItem(.flexible())],
                          alignment: .leading, spacing: Spacing.space2) {
                    ForEach(attachments) { item in
                        ReportAttachmentChip(item: item) { attachments.removeAll { $0.id == item.id } }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("report.attachments")
            }
        }
    }

    private var dropHint: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Color.surfaceCanvas.opacity(0.92))
            RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: Spacing.space2) {
                Image(systemName: "paperclip").font(.system(size: 28)).foregroundStyle(Color.textSecondary)
                Text(CopyKey("report.attach.drop")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            }
        }
        .padding(Spacing.space3)
        .allowsHitTesting(false)
    }

    static var limitArgs: [String: String] {
        ["max": String(ReportAttachments.maxCount), "size": "\(ReportAttachments.maxTotalBytes / (1024 * 1024)) MB"]
    }

    /// What to say when something was left out (nil: everything was added).
    static func message(for refusal: ReportAttachments.Refusal?) -> CopyText? {
        switch refusal {
        case nil: nil
        case .tooMany: CopyText(CopyKey("report.attach.tooMany"), limitArgs)
        case .tooLarge(let name): CopyText(CopyKey("report.attach.tooLarge"), limitArgs.merging(["name": name]) { $1 })
        case .unreadable(let name): CopyText(CopyKey("report.attach.unreadable"), ["name": name])
        }
    }

    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let outcome = ReportAttachments.add(urls, to: attachments)
        attachments = outcome.items
        note = Self.message(for: outcome.refusal)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = CopyKey("report.attach.pick").string()
        guard panel.runModal() == .OK else { return }
        attach(panel.urls)
    }

    /// Copied files, or a picture when the clipboard has no text (a text paste stays with the text field).
    @MainActor static func pastedFiles(_ pasteboard: NSPasteboard = .general) -> [URL] {
        let fileURLs: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let hasFiles = pasteboard.canReadObject(forClasses: [NSURL.self], options: fileURLs)
        if !hasFiles, pasteboard.string(forType: .string) != nil { return [] }
        return PasteHandler.fileURLs(from: pasteboard)
    }

    /// ⌘V while this sheet is up: a picture or copied files become attachments; anything else is a normal paste.
    private func watchPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v", event.window?.isSheet == true else { return event }
            let files = MainActor.assumeIsolated { Self.pastedFiles() }
            guard !files.isEmpty else { return event }
            MainActor.assumeIsolated { attach(files) }
            return nil
        }
    }

    /// The files a browser issue or the clipboard cannot carry, selected in Finder so they can be dragged in.
    private func reveal(_ r: ProblemReport) {
        let files = [r.logBundle].compactMap { $0 } + r.attachments
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    func report() async -> ProblemReport {
        var logs: URL?
        if attachLogs {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(LogBundleBuilder.fileName())
            if (try? await DiagnosticsCenter.shared.buildLogBundle(to: url, includeContent: false, database: database)) != nil { logs = url }
        }
        return ProblemReport(whatHappened: details, steps: steps, systemBlock: systemBlock,
                             chatText: includeChat ? chatText : nil, logBundle: logs, attachments: attachments.map(\.url))
    }

    private func send(email: Bool) {
        guard let endpoints = DiagnosticsCenter.shared.endpoints else { return }
        Task { @MainActor in await send(email: email, endpoints: endpoints) }
    }

    private func send(email: Bool, endpoints: ReportEndpoints) async {
        let r = await report()
        let handoff = DiagnosticsCenter.shared.handoff
        if email {
            let m = ReportProblemComposer.email(r, endpoints: endpoints, payloadFile: nil)
            if handoff.composeEmail(to: m.recipient, subject: m.subject, body: m.body, attachments: m.attachments) {
                onClose()
            } else {
                note = CopyText(CopyKey("report.noEmail"))
            }
        } else {
            handoff.openGitHub(ReportProblemComposer.githubURL(r, endpoints: endpoints), fullText: ReportProblemComposer.body(r))
            note = CopyText(CopyKey(r.attachments.isEmpty ? "report.copied" : "report.attach.github"))
            // The issue body says the log bundle and the attachments are added separately: show them so they can be
            // dragged in (review fix).
            reveal(r)
        }
    }
}

/// One attached file: a small thumbnail (the picture itself, or a document glyph), its name and size, and Remove.
struct ReportAttachmentChip: View {
    let item: ReportAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.space2) {
            thumbnail
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.name).typeStyle(.footnote).foregroundStyle(Color.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                    .typeStyle(.caption).foregroundStyle(Color.textSecondary)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(CopyText(CopyKey("report.attach.remove"), ["name": item.name])))
            .accessibilityIdentifier("report.attachment.remove")
        }
        .padding(Spacing.space1)
        .padding(.trailing, Spacing.space1)
        .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("report.attachment")
        .help(Text(verbatim: item.name))
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = Self.thumbnail(item.url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.surfaceCanvas
                Image(systemName: "doc").font(.system(size: 14)).foregroundStyle(Color.textSecondary)
            }
        }
    }

    /// A downsampled picture (never the full image in memory); nil for anything that is not an image.
    static func thumbnail(_ url: URL, side: Int = 56) -> NSImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
