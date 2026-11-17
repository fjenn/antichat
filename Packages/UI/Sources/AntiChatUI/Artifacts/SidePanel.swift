// SidePanel (M4.T11 step 1, components §4, S-15; Cetus `ArtifactsPanel` design port, P-files-tools-07). A trailing
// panel beside the conversation: header (title, version picker, Save As, Open, ×), body = PDFKit for PDFs (text
// selection; M6.T02 page pills jump to the cited page, M6.T13), selectable text for text/CSV/code, an image view for images,
// SandboxedWebPreview for HTML/SVG, Quick Look for the rest. Opens in 320 ms (none under Reduce Motion); the divider
// resizes it and the width is remembered per window. A custom split instead of `.inspector` because the inspector
// does not report its width (needed to remember it) — same behaviour, minor.
import AntiChatDesign
import AntiChatTools
import PDFKit
import SwiftUI

public struct SidePanelContainer<Content: View>: View {
    @Bindable var model: SidePanelModel
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var available: CGFloat = .infinity

    public init(model: SidePanelModel, @ViewBuilder content: () -> Content) {
        self.model = model
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.isOpen {
                ResizeHandle(model: model, shown: model.shownWidth(in: available))
                SidePanel(model: model)
                    .frame(width: model.shownWidth(in: available))
                    .transition(.move(edge: .trailing))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: SidePanelModel.openDuration), value: model.isOpen)
    }
}

/// The divider between the conversation and the panel: drag it to resize. A drag starts from the width on screen
/// (`shown`), not the remembered one: a remembered 900 pt panel drawn at 545 pt (the conversation keeps
/// `minChatWidth`) otherwise ignored the first 355 pt of a narrowing drag. For assistive tech it is a "Panel width"
/// slider (40 pt steps), not an unlabelled element of no role.
private struct ResizeHandle: View {
    let model: SidePanelModel
    let shown: CGFloat
    @State private var start: CGFloat?

    static let step: CGFloat = 40

    var body: some View {
        Rectangle().fill(Color.borderSubtle).frame(width: 1)
            .overlay { Color.clear.frame(width: 8).contentShape(Rectangle()) }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)  // the handle moves with the drag: local translation lagged the pointer
                .onChanged { g in
                    let base = start ?? shown
                    start = base
                    model.resize(to: base - g.translation.width)
                }
                .onEnded { _ in start = nil })
            // A slider for assistive tech (AXSlider: a role, a name, a value, increment / decrement); an adjustable
            // action alone left the element without a role on macOS ("Unknown role" in the audit).
            .accessibilityRepresentation {
                Slider(value: Binding(get: { Double(min(max(shown, SidePanelModel.minWidth), SidePanelModel.maxWidth)) },
                                      set: { model.resize(to: CGFloat($0)) }),
                       in: Double(SidePanelModel.minWidth)...Double(SidePanelModel.maxWidth), step: Double(Self.step)) {
                    Text(CopyKey("panel.resize"))
                }
            }
            .accessibilityIdentifier("sidePanelResize")
    }
}

public struct SidePanel: View {
    @Bindable var model: SidePanelModel
    @State private var saveError: String?
    /// The live web preview (M6.T13 Download .pdf / .svg / .png render from it).
    @State private var web: SandboxedWebController?
    @State private var downloadToast: Toast?
    @State private var copied = false

    public init(model: SidePanelModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack(alignment: .bottom) {
                bodyView.frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.canEditSelection {
                    Button {
                        if model.editsInPlace { model.editingSelection = true } else { model.editSelection() }
                    } label: { Text(CopyKey("panel.editSelection")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .controlSize(.regular)
                        .padding(Spacing.space3)
                        .accessibilityIdentifier("panelEditSelection")
                        .popover(isPresented: $model.editingSelection, arrowEdge: .top) { EditSelectionPopover(model: model).popoverSurface() }
                }
            }
        }
        .background(Color.surfaceCanvas)
        .toast($downloadToast)
        .accessibilityElement(children: .contain)  // keeps panelEditSelection & co. (Q-015 catch-up)
        .accessibilityIdentifier("sidePanel")
    }

    private var header: some View {
        HStack(spacing: Spacing.space2) {
            Text(verbatim: model.title).typeStyle(.headline).foregroundStyle(Color.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("panelTitle")
            VersionPicker(model: model)
            Spacer(minLength: Spacing.space2)
            if model.previewError != nil, model.editsInPlace {  // M6.T13 R-016 AC3: the preview reported an error
                Button { model.fix() } label: { Label { Text(CopyKey("panel.fix")) } icon: { Image(systemName: "wand.and.stars") } }
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
                    .help(model.previewError ?? "")
                    .accessibilityIdentifier("panelFix")
            }
            if let current = model.current {
                Button {  // M6.T13 R-016 AC3: Copy (source text; binary → file URL)
                    ArtifactExport.copy(url: current.url)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: { PanelGlyph(symbol: copied ? "checkmark" : "square.on.square") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.textSecondary)  // VQ-M10: neutral, not accent-blue
                    .help(CopyKey(copied ? "msg.copied" : "msg.copy").string())
                    .accessibilityLabel(Text(CopyKey("msg.copy")))
                    .accessibilityIdentifier("panelCopy")
                Menu {
                    ForEach(ArtifactExport.formats(preview: model.previewMode, body: model.body, url: current.url), id: \.self) { f in
                        Button {
                            let (title, preview, language, web) = (model.title, model.previewMode, model.language, web)
                            Task {
                                let r = await ArtifactExport.download(f, title: title, url: current.url, preview: preview,
                                                                      language: language, web: web)
                                if let t = ArtifactExport.toast(for: r) { downloadToast = t }  // M6 review #17
                            }
                        } label: { Text(verbatim: f.label) }
                        .accessibilityLabel(Text(CopyText(CopyKey("panel.download.a11y"), ["title": model.title, "format": f.label])))
                        .accessibilityIdentifier("panelDownload.\(f.ext)")
                    }
                } label: { PanelGlyph(symbol: "arrow.down.circle") }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(Color.textSecondary)
                    .tint(Color.textSecondary)  // round 65: a borderless menu's label took the accent
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(CopyKey("panel.download").string())
                    .accessibilityLabel(Text(CopyKey("panel.download")))
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .accessibilityIdentifier("panelDownload")
                Button {
                    Task {
                        let vm = FileCardViewModel(item: FileCardItem(url: current.url, displayName: model.title))
                        await vm.saveAs()
                    }
                } label: { PanelGlyph(symbol: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.textSecondary)  // VQ-M10: neutral, not accent-blue
                    .help(CopyKey("file.saveAs").string())
                    .accessibilityLabel(Text(CopyKey("file.saveAs")))
                    .accessibilityIdentifier("panelSaveAs")
                Button {
                    // M6 review #6: external apps edit a named copy, never the shared content-addressed blob.
                    FileCardViewModel(item: FileCardItem(url: current.url, displayName: model.title)).open()
                } label: {
                    // VQ-M10 round 65 (S-15): the panel's main action carries its word, not only a glyph.
                    // "Open in app": the file's own app (Word, Preview…). The card's button is "Preview" (this panel).
                    Label { Text(CopyKey("file.openInApp")).lineLimit(1) } icon: { Image(systemName: "arrow.up.forward.app") }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, Spacing.space2)
                        .frame(height: 26)
                        .background(Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control))
                        .contentShape(Capsule())
                }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .accessibilityLabel(Text(CopyKey("file.openInApp")))
                    .accessibilityIdentifier("panelOpen")
            }
            Button { model.close() } label: { PanelGlyph(symbol: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.textSecondary)  // VQ-M10: the close × read as tiny accent-blue
                .help(CopyKey("panel.close").string())
                .accessibilityLabel(Text(CopyKey("panel.close")))
                .accessibilityIdentifier("panelClose")
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.space3)
        .frame(height: 44)
    }

    @ViewBuilder private var bodyView: some View {
        if let sources = model.sources {
            SourcesPanel(content: sources)  // M7.T03 step 8
        } else if let current = model.current {
            switch model.body {
            case .pdf:
                PDFBody(url: current.url, page: model.page, selection: $model.selection).id("\(current.url.path)#\(model.page ?? 0)")
            case .text:
                TextBody(url: current.url, selection: $model.selection).id(current.url)
            case .image:
                if let image = NSImage(contentsOf: current.url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(Spacing.space3)
                        .accessibilityIdentifier("panelImage")
                }
            case .web:
                SandboxedWebPreview(url: current.url, mode: model.previewMode,
                                    onError: { [model] in model.previewError = $0 },
                                    onController: { web = $0 })
                    .id("\(current.url.path)|\(model.previewMode?.rawValue ?? "")")
            case .quickLook:
                // A spreadsheet reads as the app's own table (Quick Look draws it in a serif face with black rules).
                if current.url.pathExtension.lowercased() == "xlsx" {
                    SheetBody(url: current.url).id(current.url)
                } else if current.url.pathExtension.lowercased() == "docx" {
                    // A Word document as a page that wraps to the panel's width (Quick Look drew it at a fixed page
                    // width, cut off on the right, with a "Page of" footer whose numbers it cannot fill in).
                    DocBody(url: current.url).id(current.url)
                } else {
                    InlineQuickLook(url: current.url).id(current.url)
                }
            }
        }
    }
}

/// An .xlsx file as tables in the chat's table style; Quick Look when it cannot be read.
struct SheetBody: View {
    let url: URL
    @State private var markdown: String??

    var body: some View {
        Group {
            switch markdown {
            case .some(.some(let md)):
                ScrollView([.vertical]) {
                    MessageMarkdownView(text: md, streaming: false, interrupted: false, live: nil)
                        .padding(Spacing.space4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("panelSheet")
            case .some(.none): InlineQuickLook(url: url)
            case .none: Color.clear
            }
        }
        .task { markdown = .some(await SheetLoader.previewMarkdown(xlsx: url)) }
    }
}

/// A .docx file's text and formatting on a white page as wide as the panel; Quick Look when it cannot be read.
struct DocBody: View {
    let url: URL
    @State private var text: NSAttributedString??

    var body: some View {
        Group {
            switch text {
            case .some(.some(let t)): DocTextView(text: t).accessibilityIdentifier("panelDoc")
            case .some(.none): InlineQuickLook(url: url)
            case .none: Color.clear
            }
        }
        .task {
            let url = url, folder = DragOut.stagingRoot(for: url)
            let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
                // Read through a copy the system reader understands (DocxPreview: "not bold" must not read as bold).
                let copy = DocxPreview.readableCopy(of: url, in: folder)
                defer { if let copy { try? FileManager.default.removeItem(at: copy) } }
                return Loaded(text: try? NSAttributedString(url: copy ?? url,
                                                            options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                                            documentAttributes: nil))
            }.value
            text = .some(loaded.text.flatMap { $0.length > 0 ? $0 : nil })
        }
    }

    private struct Loaded: @unchecked Sendable { let text: NSAttributedString? }
}

/// Read-only rich text on a page: always dark text on white (the document's own colours), whatever the app's theme.
private struct DocTextView: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        scroll.appearance = NSAppearance(named: .aqua)
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = NSSize(width: 28, height: 28)
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true  // the page is as wide as the panel: nothing is cut off
        view.textStorage?.setAttributedString(text)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {}
}

/// "Version {current} of {total}" menu (M4.T11 step 3); hidden for a single version.
public struct VersionPicker: View {
    let model: SidePanelModel

    public var body: some View {
        if let label = model.versionLabel {
            Menu {
                ForEach(model.versions.reversed()) { v in
                    Button { model.select(version: v.n) } label: {
                        Text(CopyText(CopyKey("file.version"), ["n": String(v.n)]))
                    }
                    .accessibilityIdentifier("panelVersion\(v.n)")
                }
            } label: { Text(label) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
            .accessibilityIdentifier("panelVersionPicker")
        }
    }
}

/// PDFKit body: selection feeds "Edit selection"; `PDFBody.go(to:)` hook for M6.T02 page pills.
struct PDFBody: NSViewRepresentable {
    let url: URL
    /// M6.T13 (R-277 AC1): the cited page a page pill jumps to (1-based).
    var page: Int? = nil
    @Binding var selection: String

    func makeNSView(context: Context) -> PDFContainerView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        if let page, let p = view.document?.page(at: max(0, page - 1)) { view.go(to: p) }
        let container = PDFContainerView(pdf: view, name: url.lastPathComponent)
        context.coordinator.container = container
        context.coordinator.observe(view)
        SelectionCoordinator.announcePage(view, on: container)
        return container
    }

    func updateNSView(_ view: PDFContainerView, context: Context) { context.coordinator.binding = $selection }

    /// Q-015 r6: PDFView is an ignored accessibility container (like AVPlayerView, P50), so its identifier and page
    /// value never reached VoiceOver or XCUITest (`panelPDF` not found). The container is the named group
    /// (`panelPDF`, value "p. 3") around it; the document's own elements stay its children.
    final class PDFContainerView: NSView {
        let pdf: PDFView
        init(pdf: PDFView, name: String) {
            self.pdf = pdf
            super.init(frame: .zero)
            pdf.frame = bounds
            pdf.autoresizingMask = [.width, .height]
            addSubview(pdf)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel(name)  // the document's file name, as the panel title shows it
            setAccessibilityIdentifier("panelPDF")
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    func makeCoordinator() -> SelectionCoordinator { SelectionCoordinator(binding: $selection) }

    @MainActor final class SelectionCoordinator: NSObject {
        var binding: Binding<String>
        weak var container: NSView?
        init(binding: Binding<String>) { self.binding = binding }
        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)),
                                                   name: .PDFViewSelectionChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(pageChanged(_:)),
                                                   name: .PDFViewPageChanged, object: view)
        }
        @objc func pageChanged(_ note: Notification) {
            if let v = note.object as? PDFView, let container { Self.announcePage(v, on: container) }
        }
        /// Q-015 r5: the shown page as the panel's accessibility value ("p. 3", `files.pageCite`), so VoiceOver and the
        /// UI tests can tell where a page pill opened the document.
        static func announcePage(_ view: PDFView, on container: NSView) {
            guard let doc = view.document, let p = view.currentPage else { return }
            container.setAccessibilityValue(CopyText(CopyKey("files.pageCite"), ["page": "\(doc.index(for: p) + 1)"]).string)
        }
        @objc func changed(_ note: Notification) {
            let text = (note.object as? PDFView)?.currentSelection?.string ?? ""
            binding.wrappedValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Read-only selectable text (TXT / MD / CSV / code / JSON).
struct TextBody: NSViewRepresentable {
    let url: URL
    @Binding var selection: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text.delegate = context.coordinator
        text.setAccessibilityIdentifier("panelText")
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.binding = $selection }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $selection) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }
        func textViewDidChangeSelection(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            let selected = view.selectedRanges.map { (view.string as NSString).substring(with: $0.rangeValue) }.joined(separator: "\n")
            binding.wrappedValue = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// VQ-M10 round 65 (S-15): a panel header glyph at the toolbar's size (15 pt in a 28 pt target, hover fill); the
/// small-control glyphs read as tiny and unlabelled. Each button keeps its tooltip and accessibility label.
private struct PanelGlyph: View {
    let symbol: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .regular))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(hovering ? Color.surfaceHover : Color.clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
