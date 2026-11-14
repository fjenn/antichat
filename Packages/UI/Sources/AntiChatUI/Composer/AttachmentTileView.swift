// M6.T01 step 8/9 (components.md AttachmentTile; S-14; IS-10): a file in the composer tray. States: reading (progress
// ring + `status.reading` / `status.readingScan`), ready (image / PDF first-page thumbnail via QLThumbnailGenerator,
// sheet glyph + `tile.sheet`, audio glyph + `tile.audio`, others a type glyph + `tile.pages` / `tile.slides`; footer
// name truncated in the middle), error (red border, `upload.failed`; the toast carries the reason), too large
// (`upload.tooLarge`), unsupported (`upload.unsupported`), encrypted (`file.encrypted` + a password field kept in
// memory only). × on hover removes it; a click on a ready tile opens Quick Look (M4 plumbing). Accessibility label
// "<name>, <type>, <state>"; the × reads "Remove <name>".
import AntiChatDesign
import AntiChatKnowledge
import AppKit
import SwiftUI

struct AttachmentTileView: View {
    let attachment: ComposerAttachment
    let item: IntakeItem?
    let onRemove: () -> Void
    let onUnlock: (String) -> Void
    /// M5.T10: Animate this picture (nil = not offered: not an image, not ready, or video unavailable).
    var onAnimate: (() -> Void)? = nil

    @State private var hovering = false
    @State private var password = ""
    @State private var thumbnail: NSImage?
    @State private var quickLook: URL?

    static let size = PasteAttachmentCard.size

    private var name: String { item?.displayName ?? attachment.fileURL?.lastPathComponent ?? "" }
    private var state: IntakeState { item?.state ?? .ready }
    private var kind: AttachmentKind { item?.kind ?? .unknown }
    private var isError: Bool { state.isTerminalError }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content
                .padding(Spacing.space2)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
                // VQ-M10 round 65 (S-14, ChatGPT 005): an error tile is a grey tile with the red reason, not a red
                // frame around red text (the blind panel's "small red on red").
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(isError ? Color.surfaceHover : hovering && state == .ready ? Color.surfaceHover : Color.surfaceCanvas))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
                .onTapGesture { if state == .ready { quickLook = item?.storedURL ?? attachment.fileURL } }
                .accessibilityAction { if state == .ready { quickLook = item?.storedURL ?? attachment.fileURL } }  // M9.T01
                .quickLookPreview($quickLook)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: "\(name), \(Self.typeName(kind)), \(stateText)"))
                .probeID("fileTile")
                .accessibilityValue(Text(verbatim: probeState))
                #if DEBUG
                // Q-015 r5 (AudioFileTests): every state line the tile renders, for a transcription that ends faster
                // than an accessibility client can poll the tile (DEBUG `ANTICHAT_TILE_STATE_LOG=<file>`).
                .onChange(of: "\(probeState)\t\(stateText)", initial: true) { _, line in TileStateLog.append(line) }
                #endif

            if hovering, let onAnimate {
                AttachmentAnimateButton(action: onAnimate)
                    .padding(Spacing.space1)
                    .frame(width: Self.size.width, height: Self.size.height, alignment: .bottomTrailing)
            }
            // VQ-M10 round 65 (S-14): every tile shows its × (a ready tile had none until hovered).
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.buttonPrimaryFg)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.buttonPrimaryBg))
                    .contentShape(Circle().inset(by: -5))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help(CopyText(CopyKey("tile.remove"), ["name": name]).string)
            .accessibilityLabel(Text(CopyText(CopyKey("tile.remove"), ["name": name])))
            .probeID("fileTileRemove")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
        // Q-015 r3: hover is the whole tile, its buttons included (only here). A second `onHover` on the content ended
        // the hover when the pointer moved onto Animate (a layer above it): the button went away and the click landed
        // on the tile (Quick Look) instead of `onAnimateAttachment`.
        .onHover { hovering = $0 }
        // VQ-M10 S-14: keyed on the ready state too — `storedURL` lands while the tile is still reading, and a task
        // keyed on it alone ran once then (not ready: no thumbnail) and never again, so photos kept the generic glyph.
        .task(id: ThumbnailKey(url: item?.storedURL, ready: state == .ready)) { await loadThumbnail() }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            switch state {
            case .reading(let fraction):
                // VQ-M10 S-14: a determinate ring that fills as the file is read, with the percent beside the glyph
                // (ChatGPT's upload ring on its tile); the tile line is short ("Reading… 40%"), the name stays below.
                HStack(spacing: Spacing.space2) {
                    ReadingRing(fraction: fraction)
                    Image(systemName: Self.symbol(kind)).font(.system(size: 14)).foregroundStyle(Color.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                caption(fraction == nil ? CopyKey("tile.readingStart").string()
                            : CopyText(CopyKey("tile.reading"), ["percent": "\(Self.shownPercent(fraction))"]).string,
                        secondary: true)
            case .scanning(let page, let pages):  // M6.T04 (R-271 AC2): sendable while OCR runs
                ProgressView(value: Double(page), total: Double(max(1, pages))).progressViewStyle(.circular).controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                caption(stateText, secondary: true)
            case .transcribing(let percent):  // M3.T06 (R-056): the helper's real % (processed seconds ÷ duration)
                ProgressView(value: percent, total: 100).progressViewStyle(.circular).controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                caption(stateText, secondary: true)
            case .encrypted:
                // VQ-M10 S-14: the lock sits inline with the line, so line + field + name fit the tile (the name was
                // clipped under the field).
                Spacer(minLength: 0)
                inlineCaption("lock.fill", CopyText(CopyKey("file.encrypted")).string, color: .textSecondary, lines: 2)
                SecureField(CopyKey("file.encrypted.enter").string(), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .onSubmit { if !password.isEmpty { onUnlock(password); password = "" } }
                    .probeID("fileTilePassword")
            case .failed, .tooLarge, .unsupported, .locked:
                // VQ-M10 S-14: inline icon + up to 3 lines, so the reason is never cut ("too large (537.9 MB; li…").
                Spacer(minLength: 0)
                inlineCaption("exclamationmark.triangle.fill", stateText, color: .danger, lines: 3)
                Spacer(minLength: 0)
            case .ready:
                if let thumbnail {
                    // VQ-M10: the picture fills the space left above the name (an aspect-fill image as the stack's
                    // own child asked for its full height and pushed the name and detail out of the tile).
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay { Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill) }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                } else {
                    glyph(Self.symbol(kind))
                }
                if let detail = readyDetail { caption(detail, secondary: true) }
            }
            Text(verbatim: name)
                .typeStyle(.footnote)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func glyph(_ symbol: String, color: Color = .textSecondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func inlineCaption(_ symbol: String, _ s: String, color: Color, lines: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color)
            Text(verbatim: s)
                .typeStyle(.footnote)
                .foregroundStyle(color)
                .lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(s)
    }

    private func caption(_ s: String, secondary: Bool, danger: Bool = false) -> some View {
        Text(verbatim: s)
            .typeStyle(.footnote)
            .foregroundStyle(danger ? Color.danger : secondary ? Color.textSecondary : Color.textPrimary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The visible state line (also the accessibility state).
    var stateText: String { Self.stateText(state, name: name, item: item) }

    static func stateText(_ state: IntakeState, name: String, item: IntakeItem?) -> String {
        switch state {
        case .reading(let f):
            CopyText(CopyKey("status.reading"), ["file": name, "percent": "\(shownPercent(f))"]).string
        case .ready: readyDetail(item) ?? typeName(item?.kind ?? .unknown)
        case .failed: CopyKey("upload.failed").string()
        case .tooLarge(let size):
            CopyText(CopyKey("upload.tooLarge"), ["file": name, "size": ByteCountFormatter.string(fromByteCount: size, countStyle: .file),
                                                  "limit": item?.kind.isAudio == true ? CopyKey("upload.limitAudio").string()
                                                      : AttachmentLimits.maxFileLabel]).string
        case .unsupported(let ext): CopyText(CopyKey("upload.unsupported"), ["ext": ".\(ext)"]).string
        case .locked(let ext): CopyText(CopyKey("upload.locked"), ["ext": ".\(ext)"]).string
        case .encrypted: CopyKey("file.encrypted").string()
        case .scanning(let page, let pages): CopyText(CopyKey("status.readingScan"), ["page": "\(page)", "pages": "\(pages)"]).string
        case .transcribing(let percent):
            CopyText(CopyKey("status.transcribing"), ["file": name, "percent": "\(Int(percent.rounded(.down)))"]).string
        }
    }

    private var readyDetail: String? { Self.readyDetail(item) }

    /// The percent a reading tile shows: rounded down and at most 99 (only `ready` is done; a tile never reads
    /// "Reading… 100%" while it is still working).
    static func shownPercent(_ f: Double?) -> Int { min(99, max(0, Int(((f ?? 0) * 100).rounded(.down)))) }

    static func readyDetail(_ item: IntakeItem?) -> String? {
        guard let item, let doc = item.document else { return nil }
        if item.kind.isAudio {  // M3.T06: the duration once the transcript is in, else still pending (no Voice pack)
            guard !doc.transcriptionPending else { return CopyKey("tile.transcriptPending").string() }
            return CopyText(CopyKey("tile.audio"), ["duration": AudioIntakeAdapter.durationLabel(item.duration ?? 0)]).string
        }
        if let sheets = doc.sheetCount {
            return CopyText(CopyKey("tile.sheet"), ["sheets": "\(sheets)", "rows": (doc.rowCount ?? 0).formatted()]).string
        }
        if let pages = doc.pageCount { return CopyText(CopyKey("tile.pages"), ["count": "\(pages)"]).string }
        if let slides = doc.slideCount { return CopyText(CopyKey("tile.slides"), ["count": "\(slides)"]).string }
        return nil
    }

    /// For the probe / UI tests: reading | ready | failed | tooLarge | unsupported | encrypted.
    private var probeState: String {
        switch state {
        case .reading: "reading"
        case .ready: "ready"
        case .failed: "failed"
        case .tooLarge: "tooLarge"
        case .unsupported: "unsupported"
        case .locked: "locked"
        case .encrypted: "encrypted"
        case .scanning: "scanning"
        case .transcribing: "transcribing"
        }
    }

    static func typeName(_ kind: AttachmentKind) -> String {
        switch kind {
        case .pdf: "PDF"
        case .docx: "Word"
        case .xlsx, .xls: "Excel"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .pptx: "PowerPoint"
        case .epub: "EPUB"
        case .unknown, .legacyOffice: "File"
        default: kind.canonicalExtension?.uppercased() ?? kind.rawValue.uppercased()
        }
    }

    static func symbol(_ kind: AttachmentKind) -> String {
        switch kind {
        case .pdf: "doc.richtext"
        case .xlsx, .xls, .csv, .tsv: "tablecells"
        case .pptx: "rectangle.on.rectangle"
        case .epub: "book"
        case .code, .json, .html: "chevron.left.forwardslash.chevron.right"
        case _ where kind.isAudio: "waveform"
        case _ where kind.isImage: "photo"
        default: "doc.text"
        }
    }

    /// Images and PDFs get a QL thumbnail (ThumbnailCache from M4.T10; never cached on disk for incognito); the glyph
    /// shows until it arrives (never blocks).
    private func loadThumbnail() async {
        guard let url = item?.storedURL, state == .ready, kind.isImage || kind == .pdf else { return }
        guard let cg = await ThumbnailCache.shared.thumbnail(for: url, side: 120,
                                                             incognito: url.path.contains("AntiChat-incognito-")) else { return }
        thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

private struct ThumbnailKey: Hashable {
    let url: URL?
    let ready: Bool
}

/// VQ-M10 S-14: the reading tile's determinate ring (indeterminate spinner when no fraction is known yet).
private struct ReadingRing: View {
    let fraction: Double?
    @Environment(\.accentPreset) private var accentPreset

    var body: some View {
        if let fraction {
            // Round 65 (S-14): an accent arc on a visible grey track (black on a near-white track read as an empty
            // circle at high percents).
            ZStack {
                Circle().stroke(Color.textPrimary.opacity(0.14), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: max(0.04, min(1, fraction)))
                    .stroke(accentPreset.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: fraction)
            }
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

#if DEBUG
/// Q-015 r5: `ANTICHAT_TILE_STATE_LOG=<file>` appends each rendered tile state line (`<state>\t<shown text>`).
enum TileStateLog {
    static let path = ProcessInfo.processInfo.environment["ANTICHAT_TILE_STATE_LOG"]

    static func append(_ line: String) {
        guard let path, let data = (line + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
