// M4.T12 step 3 (R-032 AC2, S-13): the full-window picture viewer, an overlay over the chat column.
//   Zoom (pinch, ⌘+ / ⌘−, double-click or ⌘0 to fit) and pan (ZoomableImageView); Save As… (with "Save without prompt
//   details"), Copy, Show in Finder; the variant rail (> 1 picture) and the version rail on the right (the artifact's
//   versions, newest at the top, each with its operation). Esc or Close returns to the chat at the same scroll
//   position (the transcript under the overlay never moves).
import AntiChatDesign
import AntiChatHarness
import AntiChatStorage
import GRDB
import SwiftUI

/// One version of a picture in the rail.
public struct ImageVersionItem: Sendable, Equatable, Identifiable {
    public var id: Int { n }
    public var n: Int
    public var path: String
    /// `ArtifactOperation` raw value (nil for versions stored before M4.T09).
    public var operation: String?
    /// The `artifact_version` row (M4.T13: an edit of an older version names it; nil in snapshots).
    public var versionID: String?
    public init(n: Int, path: String, operation: String?, versionID: String? = nil) {
        self.n = n; self.path = path; self.operation = operation; self.versionID = versionID
    }

    /// `viewer.op.<operation>` ("Created", "Edited", …).
    var operationKey: CopyKey? { operation.map { CopyKey("viewer.op.\($0)") } }
}

/// What the viewer shows: a job's pictures (variants), the selected one, and the artifact's version chain.
public struct ImageViewerTarget: Sendable, Equatable, Identifiable {
    public var id: String { current }
    public var paths: [String]
    public var selected: Int
    public var artifactID: String?
    /// The file shown (a variant or a version).
    public var current: String
    /// Oldest first, as stored; the rail lists them newest first.
    public var versions: [ImageVersionItem] = []
    /// M4.T13: opened from the card's Edit — the Describe the change field takes the focus.
    public var focusDescribe = false

    public init(paths: [String], selected: Int, artifactID: String?, current: String, versions: [ImageVersionItem] = [],
                focusDescribe: Bool = false) {
        self.paths = paths
        self.selected = selected
        self.artifactID = artifactID
        self.current = current
        self.versions = versions
        self.focusDescribe = focusDescribe
    }

    /// M4.T13: the id an edit of the shown picture names — the artifact id for its newest version (or when the chain is
    /// unknown), the version id for an older one (its edit becomes a sibling branch, R-033 AC2). nil = not stored.
    public var sourceID: String? {
        guard let artifactID else { return nil }
        guard let shown = versions.first(where: { $0.path == current }), let newest = versions.map(\.n).max(),
              shown.n != newest, let vid = shown.versionID else { return artifactID }
        return vid
    }

    /// The artifact's version chain, oldest first (`artifact_version` + its blob's file; R-287 AC4 operation).
    public static func versions(artifactID: String, database: AppDatabase) -> [ImageVersionItem] {
        (try? database.read { db in
            try ArtifactVersionRecord.filter(Column("artifact_id") == artifactID).order(Column("n")).fetchAll(db).compactMap { v in
                try FileBlobRecord.fetchOne(db, key: v.blobID).map {
                    ImageVersionItem(n: v.n, path: $0.path, operation: v.operation, versionID: v.id)
                }
            }
        }) ?? []
    }
}

/// Opens the viewer over the chat column (ConversationView provides it; nil outside a chat).
public struct ImageViewerOpener: @unchecked Sendable {
    let open: @MainActor (ImageViewerTarget) -> Void
    public init(_ open: @escaping @MainActor (ImageViewerTarget) -> Void) { self.open = open }
    @MainActor public func callAsFunction(_ t: ImageViewerTarget) { open(t) }
}

extension EnvironmentValues {
    @Entry public var openImageViewer: ImageViewerOpener?
}

/// M4.T13: "change this picture as described" — the source id (`ImageViewerTarget.sourceID`) and the user's words.
public struct ImageEditRequest: Sendable, Equatable {
    public var sourceID: String
    public var instruction: String
    /// The Best quality toggle: this turn's edit uses img-edit where installed (else the quick model).
    public var best: Bool
    public init(sourceID: String, instruction: String, best: Bool = false) {
        self.sourceID = sourceID; self.instruction = instruction; self.best = best
    }
}

public struct ImageViewer: View {
    @State var target: ImageViewerTarget
    /// M4.T13: Describe the change → a chat turn (nil = no field, e.g. outside a chat).
    let onEdit: ((ImageEditRequest) -> Void)?
    /// M4.T15: Erase / Remove background → a `local` job → the next version (nil = no editor toolbar).
    let onLocalEdit: (@MainActor (LocalEditRequest) async -> LocalEditOutcome)?
    let onClose: () -> Void
    @State private var command: ZoomCommand?
    @State private var serial = 0
    @State private var magnification: CGFloat = 1
    @State private var describe = ""
    @State private var bestEdit = false
    @State private var erasing = false
    @State private var strokes: [MaskStroke] = []
    @State private var brush = 1
    @State private var busy = false
    @State private var notice: CopyKey?
    /// M4 review P2-5 (R-285 AC6): Erase / Remove background found the ChildSafetyCheck files missing or damaged.
    @State private var safetyMissing: Int64?
    @Environment(\.openSettings) private var openSettings

    /// The column under the picture: Description, the editor tools and Describe the change share its width.
    static let columnWidth: CGFloat = 640

    public init(target: ImageViewerTarget, onEdit: ((ImageEditRequest) -> Void)? = nil,
                onLocalEdit: (@MainActor (LocalEditRequest) async -> LocalEditOutcome)? = nil, onClose: @escaping () -> Void) {
        _target = State(initialValue: target)
        self.onEdit = onEdit
        self.onLocalEdit = onLocalEdit
        self.onClose = onClose
    }

    /// VQ r65 (S-13): the viewer's transient states for snapshots (a typed change, Erase with strokes, a running
    /// editor job, a notice, the repair card) — before, only the idle viewer was ever captured.
    struct Start {
        var describe = ""
        var erasing = false
        var strokes: [MaskStroke] = []
        var busy = false
        var notice: CopyKey?
        var safetyMissing: Int64?
    }

    init(target: ImageViewerTarget, onEdit: ((ImageEditRequest) -> Void)?,
         onLocalEdit: (@MainActor (LocalEditRequest) async -> LocalEditOutcome)?, onClose: @escaping () -> Void, start: Start) {
        self.init(target: target, onEdit: onEdit, onLocalEdit: onLocalEdit, onClose: onClose)
        _describe = State(initialValue: start.describe)
        _erasing = State(initialValue: start.erasing)
        _strokes = State(initialValue: start.strokes)
        _busy = State(initialValue: start.busy)
        _notice = State(initialValue: start.notice)
        _safetyMissing = State(initialValue: start.safetyMissing)
    }

    public var body: some View {
        ZStack {
            Color.surfaceCanvas.ignoresSafeArea()  // opaque: the transcript never shows through (M4.T16 capture)
                .accessibilityHidden(true)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    Group {
                        if erasing, let img = ResultImageCache.image(target.current) {
                            MaskCanvas(image: img, strokes: $strokes, radius: MaskBrush.radii[brush])
                        } else if let img = ResultImageCache.image(target.current) {
                            ZoomableImageView(image: img, path: target.current, command: command) { magnification = $0 }
                                .generatedImageLabel(path: target.current, fallback: CopyKey("img.viewer.a11y").string())  // M9.T02
                                .accessibilityValue(Text(verbatim: "\(Int((magnification * 100).rounded())) %"))
                        } else {
                            Color.surfaceSunken
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ImageDescriptionField(path: target.current)  // M9.T02 (NFR-A5)
                        .frame(maxWidth: Self.columnWidth)
                        .padding(.horizontal, Spacing.space4)
                        .padding(.top, Spacing.space2)
                    if target.paths.count > 1 {
                        VariantStrip(paths: target.paths, selected: Binding(
                            get: { target.selected },
                            set: { i in target.selected = i; target.current = target.paths[i] }))
                            .padding(Spacing.space3)
                    }
                    bottomBar
                }
                if target.versions.count > 1 {
                    Divider()
                    VersionRail(versions: target.versions, current: target.current) { target.current = $0.path }
                        .frame(width: 168)
                }
            }
        }
        .onExitCommand { if erasing { erasing = false; strokes = [] } else { onClose() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imageViewer")
    }

    /// S-13 bottom bar: the editor toolbar (M4.T15: Erase, Remove background) and Describe the change (M4.T13).
    @ViewBuilder private var bottomBar: some View {
        if let source = target.sourceID, onEdit != nil || onLocalEdit != nil {
            VStack(spacing: Spacing.space2) {
                if let safetyMissing {
                    SafetyMissingCard(sizeBytes: safetyMissing) { SettingsNavigator.shared.request(.capabilities); openSettings() }
                } else if let notice {
                    Text(notice).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .accessibilityIdentifier("editor.notice")
                }
                // VQ r65 (S-13): two rows in the column the Description uses — the tools (and Best quality) above, the
                // Describe the change field below at its full width. One row squeezed the tool chips (their borders
                // were clipped) and the field between them.
                HStack(spacing: Spacing.space2) {
                    if onLocalEdit != nil {
                        EditorToolbar(busy: busy, erasing: erasing, canErase: !strokes.isEmpty,
                                      onErase: { notice = nil; strokes = []; erasing = true },
                                      onRemoveBackground: { local(LocalEditRequest(sourceID: source, operation: .removeBackground)) },
                                      onApplyErase: { applyErase(source) },
                                      onCancelErase: { erasing = false; strokes = [] },
                                      brush: $brush)
                            .fixedSize()
                    }
                    Spacer(minLength: Spacing.space2)
                    if onEdit != nil, !erasing {
                        Toggle(isOn: $bestEdit) { Text(CopyKey("editor.bestQuality")).typeStyle(.footnote) }
                            .toggleStyle(.checkbox)
                            .fixedSize()
                            .help(CopyKey("editor.bestQuality.help").string())
                            .accessibilityIdentifier("editor.bestQuality")
                    }
                }
                if let onEdit, !erasing {
                    DescribeChangeField(text: $describe, focusOnAppear: target.focusDescribe) { text in
                        onEdit(ImageEditRequest(sourceID: source, instruction: text, best: bestEdit))
                    }
                }
            }
            .frame(maxWidth: Self.columnWidth)
            .padding(.horizontal, Spacing.space4)
            .padding(.vertical, Spacing.space3)
            .frame(maxWidth: .infinity)
        }
    }

    /// Erase: the strokes → an 8-bit mask at the picture's pixel size → a local job.
    private func applyErase(_ source: String) {
        guard let size = ImageEditFlow.pixelSize(target.current),
              let mask = MaskBrush.png(strokes, width: size.width, height: size.height) else { notice = CopyKey("media.error"); return }
        local(LocalEditRequest(sourceID: source, operation: .erase, mask: mask))
    }

    /// Runs a direct editor action; the new version becomes the shown one, at the top of the rail.
    private func local(_ request: LocalEditRequest) {
        guard let onLocalEdit, !busy else { return }
        busy = true
        notice = nil
        safetyMissing = nil
        Task { @MainActor in
            let outcome = await onLocalEdit(request)
            busy = false
            switch outcome {
            case .done(let path, let versions):
                target.versions = versions
                target.current = path
                erasing = false
                strokes = []
            case .noSubject: notice = CopyKey("editor.removeBg.none")
            case .notShown: notice = CopyKey("media.imageBlocked")
            case .safetyMissing(let n): safetyMissing = n
            case .failed: notice = CopyKey("media.error")
            }
        }
    }

    private func zoom(_ kind: ZoomCommand.Kind) {
        serial += 1
        command = ZoomCommand(kind: kind, serial: serial)
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.space2) {
            button("xmark", CopyKey("viewer.close"), id: "imageViewer.close", action: onClose)
                .keyboardShortcut(.cancelAction)
            Spacer()
            // VQ r65 (S-13): one zoom control, [−] [Fit] [+], instead of three look-alike magnifier glyphs with no
            // label; the picture actions carry their names (each keeps its tooltip and VoiceOver label).
            HStack(spacing: 0) {
                button("minus", CopyKey("viewer.zoomOut"), id: "imageViewer.zoomOut") { zoom(.zoomOut) }
                    .keyboardShortcut("-", modifiers: .command)
                Divider().frame(height: 16)
                Button { zoom(.fit) } label: {
                    Text(CopyKey("viewer.fit.short")).typeStyle(.footnote).foregroundStyle(Color.textPrimary)
                        .padding(.horizontal, Spacing.space2).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("0", modifiers: .command)
                .help(CopyKey("viewer.fit").string())
                .accessibilityLabel(Text(CopyKey("viewer.fit")))
                .accessibilityIdentifier("imageViewer.fit")
                Divider().frame(height: 16)
                button("plus", CopyKey("viewer.zoomIn"), id: "imageViewer.zoomIn") { zoom(.zoomIn) }
                    .keyboardShortcut("+", modifiers: .command)
            }
            .background(Capsule().fill(Color.surfaceRaised))
            .overlay { Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control).allowsHitTesting(false) }
            .fixedSize()
            Divider().frame(height: 18).padding(.horizontal, Spacing.space1)
            labeled("square.and.arrow.down", CopyKey("file.saveAs"), id: "imageViewer.save") {
                let path = target.current
                Task { await ImageActions.save(path) }
            }
            labeled("doc.on.doc", CopyKey("img.copy"), id: "imageViewer.copy") { ImageActions.copy(target.current) }
            labeled("folder", CopyKey("library.reveal"), id: "imageViewer.reveal") { ImageActions.reveal(target.current) }
        }
        .padding(.horizontal, Spacing.space4)
        .frame(height: 44)
    }

    /// A picture action with its name beside the glyph (S-13: the icon-only row was unlabeled).
    private func labeled(_ symbol: String, _ key: CopyKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(key) } icon: { Image(systemName: symbol) }
                .labelStyle(.titleAndIcon)
                .typeStyle(.footnote)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.space2)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(key.string())
        .accessibilityIdentifier(id)
    }

    private func button(_ symbol: String, _ key: CopyKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Color.textPrimary).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(key.string())
        .accessibilityLabel(Text(key))
        .accessibilityIdentifier(id)
    }
}

/// M4.T12 step 3: the versions of the picture, newest at the top, each with its operation label; click shows it.
struct VersionRail: View {
    let versions: [ImageVersionItem]
    let current: String
    let onSelect: (ImageVersionItem) -> Void

    /// Newest at the top.
    static func ordered(_ versions: [ImageVersionItem]) -> [ImageVersionItem] { versions.sorted { $0.n > $1.n } }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("viewer.versions")).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.space3).padding(.top, Spacing.space3)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    ForEach(Self.ordered(versions)) { v in
                        Button { onSelect(v) } label: { row(v) }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(v.path == current ? .isSelected : [])
                            .accessibilityIdentifier("versionRail.item.\(v.n)")
                    }
                }
                .padding(.horizontal, Spacing.space3)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("versionRail")
    }

    private func row(_ v: ImageVersionItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Group {
                if let img = ResultImageCache.image(v.path) { Image(nsImage: img).resizable().scaledToFill() } else { Color.surfaceSunken }
            }
            .frame(width: 140, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .strokeBorder(v.path == current ? Color.accentColor : Color.borderSubtle, lineWidth: v.path == current ? 2 : Stroke.control)
            }
            Text(CopyText(CopyKey("file.version"), ["n": String(v.n)]).string).typeStyle(.footnote).foregroundStyle(Color.textPrimary)
            if let key = v.operationKey {
                Text(key).typeStyle(.caption).foregroundStyle(Color.textSecondary)
            }
        }
    }
}
