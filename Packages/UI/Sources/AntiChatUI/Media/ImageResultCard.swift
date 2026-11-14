// M4.T12 (R-032 AC1, S-13, components §4 ImageJobCard done state): the finished picture with its actions.
//   * Edit (`img.edit`, when the host offers it: edit by text, M4.T13), Save (`img.save`: the save panel with
//     "Save without prompt details", M4.T09), ⋯ (`img.more`): Save As…, Copy, Show in Finder, Show prompt, Open.
//     Variations / Upscale (M11, D-026), Remove background (M4.T15) and Animate (M5) join the menu with their tasks.
//   * The actions sit on the picture's bottom edge, shown on hover and while focused (always in the accessibility
//     tree, so VoiceOver and the keyboard reach them).
//   * A job with more than one picture shows the VariantStrip under it; the selected variant is the one the actions,
//     Edit and the viewer use. In v1 `count` is 1 (variants are M11), so the strip only appears for older chats.
//   * Click the picture → the full-window ImageViewer (`openImageViewer`).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The system side of the picture actions (tests record calls instead of opening apps).
@MainActor
enum ImageActions {
    /// Save / Save As…: where to (with the "without prompt details" box), then the copy. DEBUG `-SaveImageFile` stands
    /// in for the panel (SaveImageTests, ImageViewerTests).
    static func save(_ path: String, suggestedName: String = "image.png") async {
        guard let choice = await SavePanelAccessory.choose(suggestedName: suggestedName, contentType: .png) else { return }
        do { try SavePanelAccessory.write(URL(fileURLWithPath: path), to: choice) } catch {
            AppLog.log(.ui, .error, "image save failed: \(error)")  // nothing was written (P1-4)
            AppToasts.shared.show(Toast(.warning, CopyText(CopyKey("img.saveFailed"))))
        }
    }

    /// The picture (PNG data + file URL) on the pasteboard.
    static func copy(_ path: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let url = URL(fileURLWithPath: path)
        var items: [NSPasteboardWriting] = [url as NSURL]
        if let image = NSImage(contentsOf: url) { items.insert(image, at: 0) }
        pb.writeObjects(items)
    }

    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    static func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
}

public struct ImageResultCard: View {
    /// The job's pictures (one in v1); the stored copies when the call has finished, else the gated results.
    let paths: [String]
    let aspect: CGFloat
    let promptUsed: String?
    /// The chat's artifact of the picture (its version chain feeds the viewer's rail).
    let artifactID: String?
    let onEdit: ((String) -> Void)?
    /// M5.T10 (R-043 AC1): Animate this picture (hover pill + ⋯); nil = not offered.
    let onAnimate: (() -> Void)?
    /// Snapshots: the hover actions shown without a pointer.
    let forceActions: Bool
    @Environment(\.openImageViewer) private var openViewer
    @State private var selected = 0
    @State private var hovering = false
    @State private var showPrompt = false
    @FocusState private var focused: Bool

    public init(paths: [String], aspect: CGFloat, promptUsed: String? = nil, artifactID: String? = nil,
                onEdit: ((String) -> Void)? = nil, onAnimate: (() -> Void)? = nil, forceActions: Bool = false) {
        self.forceActions = forceActions
        self.onAnimate = onAnimate
        self.paths = paths
        self.aspect = aspect
        self.promptUsed = promptUsed
        self.artifactID = artifactID
        self.onEdit = onEdit
    }

    var current: String? { paths.indices.contains(selected) ? paths[selected] : paths.first }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ZStack(alignment: .bottom) {
                picture
                actions.opacity(hovering || focused || forceActions ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control) }
            .aspectRatio(aspect, contentMode: .fit)
            .onHover { hovering = $0 }
            if paths.count > 1 {
                VariantStrip(paths: paths, selected: $selected)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imageResultCard")
    }

    private var picture: some View {
        Button {
            if let openViewer { Self.open(paths: paths, selected: selected, artifactID: artifactID, opener: openViewer) }
        } label: {
            // The picture fills the card's frame and never sizes it (scaledToFill inside a ZStack widened the card
            // to the picture's aspect when the two disagreed — M4.T16).
            Color.surfaceSunken
                .overlay {
                    if let current, let img = ResultImageCache.image(current) {
                        Image(nsImage: img).resizable().scaledToFill()
                    }
                }
                .clipped()
        }
        .buttonStyle(.plain)
        .generatedImageLabel(path: current, fallback: promptUsed)  // M9.T02 (NFR-A5): "Generated image: <description>"
        .accessibilityHint(Text(CopyKey("img.viewer.a11y")))
        .accessibilityIdentifier("imageJobCard.result")
    }

    /// Opens the viewer on the selected picture (its versions are filled in by the host).
    static func open(paths: [String], selected: Int, artifactID: String?, opener: ImageViewerOpener) {
        guard paths.indices.contains(selected) else { return }
        opener(ImageViewerTarget(paths: paths, selected: selected, artifactID: artifactID, current: paths[selected]))
    }

    private var actions: some View {
        HStack(spacing: Spacing.space2) {
            Spacer()
            if let onEdit, let current {
                pill(CopyKey("img.edit"), id: "imageResult.edit") { onEdit(current) }
            }
            if let onAnimate {
                ImageAnimateHoverButton(action: onAnimate).focused($focused)
            }
            if let current {
                pill(CopyKey("img.save"), id: "imageJobCard.save") { Task { await ImageActions.save(current) } }
                Menu {
                    Button { Task { await ImageActions.save(current) } } label: { Text(CopyKey("file.saveAs")) }
                        .accessibilityIdentifier("imageResult.saveAs")
                    Button { ImageActions.copy(current) } label: { Text(CopyKey("img.copy")) }
                        .accessibilityIdentifier("imageResult.copy")
                    if let onAnimate {
                        Button(action: onAnimate) { Text(CopyKey("video.animate")) }
                            .accessibilityIdentifier("imageJobCard.animate")
                    }
                    Button { ImageActions.reveal(current) } label: { Text(CopyKey("library.reveal")) }
                        .accessibilityIdentifier("imageResult.reveal")
                    if promptUsed != nil {
                        Button { showPrompt = true } label: { Text(CopyKey("img.showPrompt")) }
                            .accessibilityIdentifier("imageJobCard.showPrompt")
                    }
                    Divider()
                    Button { ImageActions.open(current) } label: { Text(CopyKey("img.open")) }
                        .accessibilityIdentifier("imageResult.open")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .background(Capsule().fill(Color.surfaceRaised.opacity(0.92)))
                .help(CopyKey("img.more").string())
                .accessibilityLabel(Text(CopyKey("img.more")))
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .accessibilityIdentifier("imageJobCard.more")
                .focused($focused)
                .popover(isPresented: $showPrompt) { if let promptUsed { PromptUsedPopover(prompt: promptUsed) } }
            }
        }
        .padding(Spacing.space2)
    }

    private func pill(_ key: CopyKey, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(key).typeStyle(.footnote).foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.space2).frame(height: 24)
                .background(Capsule().fill(Color.surfaceRaised.opacity(0.92)))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .accessibilityIdentifier(id)
    }
}

/// M4.T12 step 2 (R-032 AC1): thumbnails of a job's pictures; click or ←/→ (when focused) selects the shown one.
struct VariantStrip: View {
    let paths: [String]
    @Binding var selected: Int
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.space2) {
            ForEach(Array(paths.enumerated()), id: \.offset) { i, path in
                Button { selected = i } label: {
                    Group {
                        if let img = ResultImageCache.image(path) { Image(nsImage: img).resizable().scaledToFill() } else { Color.surfaceSunken }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                            .strokeBorder(i == selected ? Color.accentColor : Color.borderSubtle, lineWidth: i == selected ? 2 : Stroke.control)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CopyText(CopyKey("img.variant.a11y"), ["index": "\(i + 1)", "total": "\(paths.count)"])))
                .accessibilityAddTraits(i == selected ? .isSelected : [])
                .accessibilityIdentifier("variantStrip.item.\(i)")
            }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow) { selected = max(0, selected - 1); return .handled }
        .onKeyPress(.rightArrow) { selected = min(paths.count - 1, selected + 1); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("variantStrip")
    }
}
