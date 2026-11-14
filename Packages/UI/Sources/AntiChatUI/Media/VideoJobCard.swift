// M5.T11 (R-041, components §4 VideoJobCard, IS-8; NFR-P3, NFR-VID2/VID3, NFR-B3/B5): the card of one video job.
//   * The clip's aspect from the first frame, its chosen resolution and length, an elapsed counter every second and the
//     real % (VideoJobProgress over JobProgressModel: encode 0 %, denoise steps, decode frames; monotonic; 100 % only
//     with the result), with the stage line `video.stage.preparing` / `video.stage` (step n/N) / `video.stage.decode`
//     (frame n/N). The seconds tick and the animated preview change the card at least every second (never > 3 s still).
//   * AnimatedPreview: the latest allowed step's frames as a loop (≥ 160 px, target aspect); none yet = dot matrix.
//   * Heat / other apps (VideoJobGovernor in the helper): `thermal.serious` under the stage while paced;
//     `video.paused.hot` — the line is the [Resume] action — and `video.paused.app`.
//   * ■ `img.cancel` → MediaJobQueue.cancel (≤ NFR-VID3). Blocked → BlockedMediaTile (`media.videoBlocked`); failed;
//     cancelled; lost → `video.lost` (the line is Retry).
//   * Done (M5.T12): the InlineVideoPlayer (poster first; play/pause, scrub, loop ≤ 10 s, mute when silent, full screen,
//     Open in viewer → VideoViewer) and ⋯ `img.more`: Export MP4 (`video.export`), Show in Finder, Open.
// Only gated files reach this view.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AppKit
import SwiftUI

/// What the video card shows, folded from the queue's updates (pure; snapshot tests build it directly).
public struct VideoJobCardState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case placeholder
        case waiting(position: Int)
        case running
        case done(resultPath: String)
        case blocked
        case failed(code: String?)
        case cancelled
        case lost
    }

    public var job: String?
    public var phase: Phase = .placeholder
    public var progress = JobProgressModel()
    public var video = VideoJobStatus()
    /// width / height of the clip.
    public var aspect: CGFloat
    public var startedAt: Date
    /// The chosen clip (from the job's spec): pixel size, frames, fps. 0 = unknown.
    public var width = 0
    public var height = 0
    public var frames = 0
    public var fps = 0

    public init(job: String? = nil, aspect: CGFloat, startedAt: Date = Date()) {
        self.job = job
        self.aspect = aspect > 0 ? aspect : 16.0 / 9
        self.startedAt = startedAt
    }

    /// The chosen size and length from the job's `VideoRequest`.
    public mutating func adopt(_ r: VideoRequest) {
        width = r.width
        height = r.height
        frames = r.frames
        fps = r.fps
        if r.height > 0 { aspect = CGFloat(r.width) / CGFloat(r.height) }
    }

    /// Folds one queue update.
    public mutating func apply(_ u: MediaJobQueue.Update) {
        job = u.job
        if let v = u.video { video = v }
        switch u.state {
        case .queued: phase = .waiting(position: u.position ?? 1)
        case .running:
            phase = .running
            progress.observe(progress: VideoJobProgress.fraction(video))
        case .done:
            progress.finished()
            phase = u.resultPath.map { .done(resultPath: $0) } ?? .failed(code: "noResult")
        case .blocked: phase = .blocked
        case .failed: phase = .failed(code: u.errorCode)
        case .cancelled: phase = .cancelled
        case .lost: phase = .lost
        }
        if !isActive {
            video.paused = nil
            video.notice = nil
        }
    }

    public var isActive: Bool {
        switch phase {
        case .placeholder, .waiting, .running: true
        default: false
        }
    }

    /// "720p · 3.4 s" (nil until the spec is known).
    public var specLine: String? {
        guard width > 0, height > 0 else { return nil }
        let short = min(width, height)
        let res = [704: 720, 720: 720, 1088: 1080, 1080: 1080][short].map { "\($0)p" } ?? "\(short)p"
        guard frames > 0, fps > 0 else { return res }
        return "\(res) · \(String(format: "%.1f", Double(frames) / Double(fps))) s"
    }

    /// The stage line under the frame (nil = none).
    public var stageText: String? {
        switch phase {
        case .placeholder: return nil
        case .waiting(let position):
            return position > 1 ? CopyText(CopyKey("job.waitingPosition"), ["position": "\(position)"]).string
                : CopyKey("img.waiting").string()
        case .running:
            if video.paused == "hot" { return CopyKey("video.paused.hot").string() }
            if video.paused == "app" { return CopyKey("video.paused.app").string() }
            switch video.stage {
            case "denoise"? where video.total > 0:
                return CopyText(CopyKey("video.stage"), ["step": "\(video.step)", "total": "\(video.total)"]).string
            case "decode"?, "frames"?:
                let total = video.total > 0 ? video.total : frames
                return CopyText(CopyKey("video.stage.decode"), ["frame": "\(video.step)", "total": "\(total)"]).string
            default:
                return CopyKey("video.stage.preparing").string()
            }
        case .done, .blocked: return nil
        case .failed: return CopyKey("video.failed").string()  // VQ r65 (S-12): "… Retry", only Retry in the accent
        case .cancelled: return CopyKey("img.cancelled").string()
        case .lost: return CopyKey("video.lost").string()
        }
    }

    /// `thermal.serious` while the job is paced (not while paused).
    public var noticeText: String? {
        guard isActive, video.paused == nil, let n = video.notice else { return nil }
        return CopyKey(n).string()
    }
}

public struct VideoJobCard: View {
    let state: VideoJobCardState
    let poster: String?
    let onCancel: (() -> Void)?
    let onRetry: (() -> Void)?
    let onResume: (() -> Void)?
    @Environment(\.openVideoViewer) private var openViewer

    public init(state: VideoJobCardState, poster: String? = nil, onCancel: (() -> Void)? = nil, onRetry: (() -> Void)? = nil,
                onResume: (() -> Void)? = nil) {
        self.state = state
        self.poster = poster
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onResume = onResume
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if state.phase == .blocked {
                BlockedMediaTile(kind: .video, aspect: state.aspect)
            } else if let symbol = endedSymbol {
                endedTile(symbol)
            } else {
                frame
            }
            footer
        }
        .frame(maxWidth: ImageJobCard.maxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(phaseID)
    }

    // MARK: ended without a clip

    /// VQ r65 (S-12): a job that ended without a clip drew the full 16:9 empty frame above its line, as the image card
    /// did before (ImageJobCard.endedSymbol): a short tile with the state's glyph now; the line says what happened.
    private var endedSymbol: String? {
        switch state.phase {
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        case .lost: "arrow.clockwise.circle"
        default: nil
        }
    }

    private func endedTile(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(Color.surfaceSunken)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
            }
            .overlay {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
            }
            .frame(height: ImageJobCard.endedTileHeight)
            .frame(maxWidth: .infinity)
    }

    // MARK: frame

    private var frame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken)
            if case .done(let path) = state.phase {
                InlineVideoPlayer(url: URL(fileURLWithPath: path), poster: poster, aspect: state.aspect,
                                  onExpand: openViewer.map { open in { open(VideoViewerTarget(path: path)) } })
                    .id(path)
            } else if state.isActive {
                AnimatedPreview(frames: state.video.previewFrames, aspect: state.aspect,
                                step: state.video.previewStep ?? state.video.step, total: state.video.total)
                    .opacity(state.video.paused != nil ? 0.6 : 1)
            }
            if state.isActive {
                VStack {
                    Spacer()
                    HStack {
                        ProgressPill(percent: state.progress.percent, startedAt: state.startedAt)
                        Spacer()
                        if let onCancel {
                            Button(action: onCancel) {
                                Image(systemName: "stop.fill").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.textPrimary)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.surfaceRaised.opacity(0.9)))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(CopyKey("img.cancel").string())
                            .accessibilityLabel(Text(CopyKey("img.cancel")))
                            .accessibilityIdentifier("videoJob.cancel")
                        }
                    }
                    .padding(Spacing.space2)
                }
            }
        }
        .frame(minHeight: AnimatedPreview.minSide)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control) }
        .aspectRatio(state.aspect, contentMode: .fit)
    }

    /// M5 review P2-5: Show in Finder / Open in another app only for clips outside an incognito session's temp dir.
    static func offersFinder(_ url: URL) -> Bool { !IncognitoPaths.contains(url) }

    // MARK: footer

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Spacing.space2) {
                stageLine
                Spacer()
                if let spec = state.specLine, state.phase != .blocked {
                    Text(verbatim: spec).typeStyle(.footnote).monospacedDigit().foregroundStyle(Color.textTertiary)
                        .accessibilityIdentifier("videoJob.spec")
                }
                if case .done(let path) = state.phase {
                    let url = URL(fileURLWithPath: path)
                    Menu {
                        Button { Task { await VideoSavePanel.export(url, name: nil) } } label: { Text(CopyKey("video.export")) }
                            .accessibilityIdentifier("videoJob.export")
                        // M5 review P2-5 (as M6 review #4): an incognito clip is never handed to Finder or another app
                        // (Quick Look thumbnails, QuickTime recents outlive the session); Export stays, an explicit save.
                        if Self.offersFinder(url) {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Text(CopyKey("library.reveal")) }
                                .accessibilityIdentifier("videoJob.reveal")
                            Button { NSWorkspace.shared.open(url) } label: { Text(CopyKey("file.open")) }
                                .accessibilityIdentifier("videoJob.open")
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(CopyKey("img.more").string())
                        .accessibilityLabel(Text(CopyKey("img.more")))
                        .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                        .accessibilityIdentifier("videoJob.more")
                }
            }
            if let n = state.noticeText {
                Text(n).typeStyle(.footnote).foregroundStyle(Color.textTertiary)
                    .accessibilityIdentifier("videoJob.notice")
            }
        }
    }

    @ViewBuilder private var stageLine: some View {
        if let text = state.stageText {
            if state.phase == .running, state.video.paused == "hot", let onResume {
                Button(action: onResume) { TrailingActionLine(text: text) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("videoJob.resume")
            } else if state.phase == .lost || isFailed, let onRetry {
                Button(action: onRetry) { TrailingActionLine(text: text) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("videoJob.retry")
            } else {
                Text(text).typeStyle(.subhead).monospacedDigit().foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("videoJob.status")
            }
        }
    }

    var phaseID: String {
        switch state.phase {
        case .done: "videoJobResult"
        case .blocked: "videoJobBlocked"
        case .running where state.video.paused != nil: "videoJobPaused"
        default: "videoJobCard"
        }
    }

    private var isFailed: Bool { if case .failed = state.phase { true } else { false } }
}

/// M9.T08 R6: a status line whose last sentence is its action (`video.paused.hot` "Paused — your Mac is hot. Resume",
/// `video.lost` "… Retry"): the status reads in text.secondary like the card's other lines and only the action word
/// takes the accent, as an inline text action does (the whole line in link blue read as one long link). The line
/// stays one button. A string with no ". " before a short last part keeps the accent throughout.
struct TrailingActionLine: View {
    let text: String
    @Environment(\.accentPreset) private var accentPreset

    /// ("Paused — your Mac is hot. ", "Resume"); nil when there is no sentence break before a short last part.
    static func split(_ s: String) -> (status: String, action: String)? {
        guard let r = s.range(of: ". ", options: .backwards) else { return nil }
        let action = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !action.isEmpty, action.count <= 24, !action.contains(".") else { return nil }
        return (String(s[..<r.upperBound]), action)
    }

    static func styled(_ s: String, status: Color, action: Color) -> AttributedString? {
        guard let (lead, tail) = split(s) else { return nil }
        var a = AttributedString(lead)
        a.foregroundColor = status
        var b = AttributedString(tail)
        b.foregroundColor = action
        return a + b
    }

    var body: some View {
        Group {
            if let line = Self.styled(text, status: Color.textSecondary, action: accentPreset.color) {
                Text(line)
            } else {
                Text(text).foregroundStyle(accentPreset.color)
            }
        }
        .typeStyle(.subhead)
        .contentShape(Rectangle())
    }
}
