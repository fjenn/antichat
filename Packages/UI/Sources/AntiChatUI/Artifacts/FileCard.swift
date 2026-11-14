// FileCard view (M4.T10 step 1–3, components §4 FileCard; S-15). Icon/thumbnail tile, name (middle-truncated),
// "TYPE · size · Version n", [Open] and a ⋯ menu with Save As… / Show in Finder. Click or Space → Quick Look
// (full size); drag → a real file named `display_name`. Generating shows a spinner/progress and disables actions;
// an error turns the tile red with its reason; a new version gets an accent dot.
import AntiChatDesign
import QuickLook
import SwiftUI

public struct FileCard: View {
    @Bindable var model: FileCardViewModel
    let showsThumbnail: Bool
    let incognito: Bool
    /// When set (a turn with a side panel, M4.T11), click opens the panel and Space keeps Quick Look.
    let onOpenInPanel: (() -> Void)?
    /// M6.T09: the error state's [Try again] (`file.tryAgain`; re-runs the turn). Nil = no button.
    let onTryAgain: (() -> Void)?
    @State private var hovering = false
    @FocusState private var focused: Bool

    public static let width: CGFloat = 340
    static let tile: CGFloat = 44

    public init(model: FileCardViewModel, showsThumbnail: Bool = true, incognito: Bool = false,
                onOpenInPanel: (() -> Void)? = nil, onTryAgain: (() -> Void)? = nil) {
        self.model = model; self.showsThumbnail = showsThumbnail; self.incognito = incognito
        self.onOpenInPanel = onOpenInPanel; self.onTryAgain = onTryAgain
    }

    public var body: some View {
        HStack(spacing: Spacing.space3) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.item.displayName)
                    .typeStyle(.bodyEmph).foregroundStyle(Color.textPrimary)
                    .lineLimit(2).truncationMode(.middle)  // round 65 S-15: wraps before it cuts mid-word
                subtitle
            }
            Spacer(minLength: Spacing.space2)
            if isError, let onTryAgain {
                Button(action: onTryAgain) { Text(CopyKey("file.tryAgain")) }
                    .controlSize(.small)
                    .accessibilityIdentifier("fileCardTryAgain")
            } else {
                actions
            }
        }
        .padding(Spacing.space2)
        // Q-015 r4: at most 340 pt, never wider than the column. A fixed 340 overflowed the transcript when the side
        // panel narrowed it, and the ⋯ menu sat under the panel's resize handle: a click on it never opened the menu.
        .frame(minWidth: 0, idealWidth: Self.width, maxWidth: Self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(hovering && model.actionsEnabled ? Color.surfaceHover : Color.surfaceRaised)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(isError ? Color.danger : (focused ? Color.focusRing : Color.borderSubtle),
                              lineWidth: focused ? Stroke.focus / 1.5 : Stroke.control)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { focused = true; open() }  // a clicked card is the focused one: Space then opens Quick Look
        .accessibilityAddTraits(.isButton)  // M9.T01: VO-Space / keyboard activate it like a click
        .accessibilityAction { open() }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { model.quickLook(); return .handled }
        .onDrag { DragOut.itemProvider(for: model.item) }
        .quickLookPreview($model.quickLookURL)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fileCard")
        .accessibilityLabel(Text(verbatim: "\(model.item.displayName), \(model.subtitle)"))
    }

    private var isError: Bool { if case .error = model.item.state { true } else { false } }

    @ViewBuilder private var icon: some View {
        ZStack(alignment: .topTrailing) {
            if case .generating(let progress) = model.item.state {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken)
                    if let progress {
                        ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: Self.tile, height: Self.tile)
            } else if isError {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.danger.opacity(0.14))
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(Color.danger)
                }
                .frame(width: Self.tile, height: Self.tile)
            } else if showsThumbnail {
                FileThumbnail(url: model.item.url, kind: model.kind, side: Self.tile, incognito: incognito || model.item.incognito)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken)
                    Image(systemName: model.kind.symbol).font(.system(size: 19)).foregroundStyle(Color.textSecondary)
                }
                .frame(width: Self.tile, height: Self.tile)
            }
            if model.item.state == .newVersion {
                Circle().fill(Color.accent).frame(width: 8, height: 8).offset(x: 2, y: -2)
                    .accessibilityIdentifier("fileCardNewVersion")
            }
        }
    }

    @ViewBuilder private var subtitle: some View {
        switch model.item.state {
        case .generating:
            Text(CopyText(CopyKey("act.creating"), ["filename": model.item.displayName]))
                .typeStyle(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
        case .error(let reason):
            Text(reason).typeStyle(.caption).foregroundStyle(Color.danger).lineLimit(1)
        case .ready, .newVersion:
            Text(verbatim: model.subtitle).typeStyle(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
        }
    }

    private var actions: some View {
        HStack(spacing: Spacing.space1) {
            Button { model.open() } label: { Text(CopyKey("file.open")) }
                .controlSize(.small)
                .accessibilityIdentifier("fileCardOpen")
                .accessibilityLabel(Text(CopyText(CopyKey("file.open.a11y"), ["filename": model.item.displayName])))
            Menu {
                Button { Task { await model.saveAs() } } label: { Text(CopyKey("file.saveAs")) }
                    .accessibilityIdentifier("fileCardSaveAs")
                    .accessibilityLabel(Text(CopyText(CopyKey("file.saveAs.a11y"), ["filename": model.item.displayName])))
                Button { model.reveal() } label: { Text(CopyKey("file.reveal")) }
                    .accessibilityIdentifier("fileCardReveal")
                    .accessibilityLabel(Text(CopyText(CopyKey("file.reveal.a11y"), ["filename": model.item.displayName])))
                Button { model.copy() } label: { Text(CopyKey("file.copy")) }
                    .accessibilityIdentifier("fileCardCopy")
                    .accessibilityLabel(Text(CopyText(CopyKey("file.copy.a11y"), ["filename": model.item.displayName])))
                if model.actionsEnabled {
                    ShareLink(item: model.sharedURL()) { Text(CopyKey("file.share")) }
                        .accessibilityIdentifier("fileCardShare")
                        .accessibilityLabel(Text(CopyText(CopyKey("file.share.a11y"), ["filename": model.item.displayName])))
                }
                // M5.T13 (D-026, AT-277): Show in Library opens the Library on this file.
                if model.actionsEnabled, !model.item.incognito {
                    Button { model.showInLibrary() } label: { Text(CopyKey("file.library")) }
                        .accessibilityIdentifier("fileCardLibrary")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
                .accessibilityLabel(Text(CopyKey("chat.more")))  // M9.T01: "More"
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
            .accessibilityIdentifier("fileCardMore")
        }
        .disabled(!model.actionsEnabled)
        .opacity(model.actionsEnabled ? 1 : 0.4)
    }
}

extension FileCard {
    /// Click, VO-Space and the default accessibility action (M9.T01): the side panel when it can, else Quick Look.
    func open() {
        if let onOpenInPanel, model.actionsEnabled { onOpenInPanel() } else { model.quickLook() }
    }
}
