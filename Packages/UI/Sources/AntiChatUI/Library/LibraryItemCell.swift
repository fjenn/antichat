// M5.T13 steps 1, 4, 5 (R-022 AC1/AC4, R-045 AC2; P-files-tools-08): one Library tile — the picture's thumbnail, the
// clip's poster (or its Quick Look frame) with its length and the `library.hasSound` icon when it has a sound track, a
// file's thumbnail or kind glyph — the name, and the `badge.evil` text badge on items from Evil chats (readable
// without colour). Thumbnails come from the shared ThumbnailCache (QuickLookThumbnailing, M4.T10) and never block.
import AntiChatDesign
import AntiChatStorage
import AVFoundation
import SwiftUI

/// "0:03" and whether the clip has sound. The length: the stored spec when there is one, else read from the file.
/// The sound: the stored spec first, then the file's tracks decide (Q-015 r6: the spec's `sound` is what the plan asked
/// for, and a clip whose file carries a sound track showed no icon — R-045 AC2 is about the clip having sound).
@MainActor @Observable
final class ClipFacts {
    var duration: Double?
    var hasSound: Bool?
    private var soundRead = false

    init(_ item: LibraryEntry) {
        duration = item.duration
        hasSound = item.hasSound
    }

    func load(_ item: LibraryEntry) async {
        guard item.kind == .video, duration == nil || !soundRead else { return }
        let asset = AVURLAsset(url: URL(fileURLWithPath: item.path))
        if duration == nil, let d = try? await asset.load(.duration).seconds, d.isFinite { duration = d }
        if !soundRead, let t = try? await asset.loadTracks(withMediaType: .audio) {
            soundRead = true
            if hasSound != !t.isEmpty { hasSound = !t.isEmpty }
        }
    }
}

struct LibraryItemCell: View {
    let item: LibraryEntry
    let selected: Bool
    static let side: CGFloat = 168
    @State private var facts: ClipFacts

    init(item: LibraryEntry, selected: Bool) {
        self.item = item
        self.selected = selected
        _facts = State(initialValue: ClipFacts(item))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            ZStack(alignment: .bottomLeading) {
                LibraryThumbnail(item: item, side: Self.side)
                HStack(spacing: Spacing.space1) {
                    if item.kind == .video {
                        LibraryClipBadge(facts: facts)
                    }
                    Spacer(minLength: 0)
                    if item.isEvil { LibraryEvilBadge() }
                }
                .padding(Spacing.space1)
            }
            .frame(width: Self.side, height: Self.side)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .strokeBorder(selected ? Color.focusRing : Color.borderSubtle, lineWidth: selected ? Stroke.focus / 1.5 : Stroke.control)
            }
            Text(verbatim: item.name).typeStyle(.caption).foregroundStyle(Color.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: Self.side, alignment: .leading)
        }
        .task(id: item.id) { await facts.load(item) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library.item")
        .accessibilityLabel(Text(verbatim: accessibilityText))
    }

    private var accessibilityText: String {
        var parts = [item.name]
        if let d = facts.duration { parts.append(InlineVideoPlayerModel.durationLabel(d)) }
        if facts.hasSound == true { parts.append(CopyKey("library.hasSound").string()) }
        if item.isEvil { parts.append(CopyKey("badge.evil").string()) }
        return parts.joined(separator: ", ")
    }
}

/// The thumbnail square: a clip's poster sidecar when present, else the Quick Look thumbnail (glyph until it loads).
struct LibraryThumbnail: View {
    let item: LibraryEntry
    let side: CGFloat
    /// Snapshot tests turn the asynchronous Quick Look path off (pictures then load synchronously, files show the glyph).
    nonisolated(unsafe) static var liveThumbnails = true

    var body: some View {
        let poster = (item.path as NSString).deletingPathExtension + ".poster.jpg"
        ZStack {
            if item.kind == .video, let img = NSImage(contentsOfFile: poster) {
                Image(nsImage: img).resizable().scaledToFill().frame(width: side, height: side).clipped()
            } else if !Self.liveThumbnails, item.kind == .image, let img = NSImage(contentsOfFile: item.path) {
                Image(nsImage: img).resizable().scaledToFill().frame(width: side, height: side).clipped()
            } else if !Self.liveThumbnails {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken)
                    Image(systemName: FileKind(item.contentType).symbol).font(.system(size: side * 0.42)).foregroundStyle(Color.textSecondary)
                }
            } else {
                FileThumbnail(url: URL(fileURLWithPath: item.path), kind: FileKind(item.contentType), side: side)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}

/// "0:03 🔊": the clip's length and, when it has a sound track, the speaker icon labelled `library.hasSound`.
struct LibraryClipBadge: View {
    let facts: ClipFacts

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold)).accessibilityHidden(true)
            if let d = facts.duration {
                Text(verbatim: InlineVideoPlayerModel.durationLabel(d)).monospacedDigit()
                    .accessibilityIdentifier("library.duration")
            }
            if facts.hasSound == true {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                    .accessibilityLabel(Text(CopyKey("library.hasSound")))
                    .accessibilityIdentifier("library.hasSound")
                    .help(CopyKey("library.hasSound").string())
            }
        }
        .typeStyle(.caption)
        .foregroundStyle(Color.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }
}

/// The text badge `badge.evil` (visible without colour).
struct LibraryEvilBadge: View {
    var body: some View {
        Text(CopyKey("badge.evil"))
            .typeStyle(.caption)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.surfaceRaised))
            .overlay(Capsule().strokeBorder(Color.textPrimary, lineWidth: 1))
            .accessibilityIdentifier("library.evilBadge")
    }
}
