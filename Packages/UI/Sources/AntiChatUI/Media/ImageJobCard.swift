// M4.T08 (R-031, S-11, components §4 ImageJobCard; IS-8, NFR-P3): the card of one image job under its tool line.
// Placeholder → queued → loading models → generating → done; blocked; failed; cancelled; lost; memory fallback.
//   * The card has the final aspect ratio from its first frame (a dot-matrix placeholder until a picture exists).
//   * `img.creating` + an elapsed-seconds counter every second and a % pill (`img.progress`): JobProgressModel —
//     real steps, monotonic, 100 % only with the result.
//   * Live previews (T3+): each allowed preview replaces the placeholder with a cross-fade (none under Reduce
//     Motion). T0–T2 have no live previews (lead decision, NFR-R1): the dot matrix keeps animating so the card
//     never stays unchanged for more than 3 s.
//   * ■ `img.cancel` → `MediaJobQueue.cancel` (the card shows `img.cancelled` when the job ends).
//   * Only gated files reach this view: previews and the result are written by the helper after the gate allowed them.
import AntiChatDesign
import AntiChatHarness
import AntiChatStorage
import SwiftUI
import UniformTypeIdentifiers

/// What the card shows, derived from the queue's updates (pure; snapshot tests build it directly).
public struct ImageJobCardState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case placeholder
        case waiting(position: Int)
        case loading
        case generating
        case done(resultPath: String)
        case blocked
        /// M4.T16: the detectors are missing/damaged (no job output): SafetyMissingCard with the repair size.
        case safetyMissing(sizeBytes: Int64)
        case failed(code: String?)
        case cancelled
        case lost
    }

    public var job: String?
    public var phase: Phase = .placeholder
    public var progress = JobProgressModel()
    public var previewPath: String?
    /// width / height of the requested picture.
    public var aspect: CGFloat
    public var startedAt: Date
    /// The job ran on a lighter model setting (`model.lighterSetting`, memory fallback).
    public var lighterSetting = false

    public init(job: String? = nil, aspect: CGFloat, startedAt: Date = Date()) {
        self.job = job
        self.aspect = aspect > 0 ? aspect : 1
        self.startedAt = startedAt
    }

    /// Folds one queue update into the state.
    public mutating func apply(_ u: MediaJobQueue.Update) {
        job = u.job
        switch u.state {
        case .queued: phase = .waiting(position: u.position ?? 1)
        case .running:
            progress.observe(progress: u.progress)
            if let p = u.previewPath { previewPath = p }
            phase = u.progress > 0 || previewPath != nil ? .generating : .loading
        case .done:
            progress.finished()
            if let r = u.resultPath { phase = .done(resultPath: r) } else { phase = .failed(code: "noResult") }
        case .blocked: phase = .blocked
        case .failed where u.errorCode == MediaJobQueue.safetyMissingCode:
            if case .safetyMissing = phase {} else { phase = .safetyMissing(sizeBytes: 0) }
        case .failed: phase = .failed(code: u.errorCode)
        case .cancelled: phase = .cancelled
        case .lost: phase = .lost
        }
    }

    public var isActive: Bool {
        switch phase {
        case .placeholder, .waiting, .loading, .generating: true
        default: false
        }
    }
}

public struct ImageJobCard: View {
    let state: ImageJobCardState
    let onCancel: (() -> Void)?
    let onRetry: (() -> Void)?
    /// R-291 AC2: Restart of an interrupted (`lost`) job — the same request again (`job.interrupted` is the action).
    /// nil = the job cannot be found (its card falls back to `img.lost` + Retry).
    var onRestart: (() -> Void)?
    /// ⋯ → Show prompt (M4.T07 step 3): the prompt the model wrote for the picture.
    let promptUsed: String?
    /// M4.T09: the stored picture (the chat's artifact, which carries the AI mark and details) that Save writes out.
    let savePath: String?
    /// M4.T12: the chat's artifact of the picture (the viewer's version rail).
    let artifactID: String?
    let onEdit: ((String) -> Void)?
    /// M5.T10 (R-043 AC1): Animate this picture (⋯ and hover on the result card); nil = not offered.
    var onAnimate: (() -> Void)?
    /// M9.T05 (NFR-P2, A-M4-R1b): called when the active progress state (dot matrix or an allowed preview, with the
    /// % pill) is put on screen.
    var onProgressShown: (() -> Void)?
    @EffectiveReduceMotion private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    public static let maxWidth: CGFloat = 512

    public init(state: ImageJobCardState, promptUsed: String? = nil, savePath: String? = nil, artifactID: String? = nil,
                onEdit: ((String) -> Void)? = nil, onCancel: (() -> Void)? = nil, onRetry: (() -> Void)? = nil,
                onAnimate: (() -> Void)? = nil, onRestart: (() -> Void)? = nil, onProgressShown: (() -> Void)? = nil) {
        self.onAnimate = onAnimate
        self.onProgressShown = onProgressShown
        self.onRestart = onRestart
        self.state = state
        self.promptUsed = promptUsed
        self.savePath = savePath
        self.artifactID = artifactID
        self.onEdit = onEdit
        self.onCancel = onCancel
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if state.phase == .blocked {
                BlockedMediaTile(kind: .image, aspect: state.aspect)
            } else if case .safetyMissing(let n) = state.phase {
                SafetyMissingCard(sizeBytes: n) { SettingsNavigator.shared.request(.capabilities); openSettings() }
            } else if case .done(let path) = state.phase {
                // M4.T12: the finished picture with its actions (the stored copy once the call has ended).
                ImageResultCard(paths: [savePath ?? path], aspect: state.aspect, promptUsed: promptUsed, artifactID: artifactID,
                                onEdit: onEdit, onAnimate: onAnimate)
            } else if let symbol = endedSymbol {
                endedTile(symbol)
            } else {
                frame
            }
            footer
        }
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .modifier(InterruptedLabel(on: state.phase == .lost && onRestart != nil))
        .accessibilityIdentifier(phaseID)
    }

    /// The interrupted card is named by its state ("Interrupted · Restart"); the others keep no label of their own.
    private struct InterruptedLabel: ViewModifier {
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.accessibilityLabel(Text(CopyKey("job.interrupted"))) } else { content }
        }
    }

    // MARK: ended without a picture

    /// vq/voice-mac-capture (S-11): a job that ended without a picture (failed, cancelled, interrupted) drew the
    /// full-size empty frame — a tall blank tile per call. It is a short tile with the state's glyph now; the footer
    /// says what happened and offers the fix.
    private var endedSymbol: String? {
        switch state.phase {
        case .failed(let code) where code == Self.unavailableCode: "photo.badge.arrow.down"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        case .lost: "arrow.clockwise.circle"
        default: nil
        }
    }

    /// The call ended without a job because this Mac's Photo models are not ready (ImageJobActivity.settled).
    static let unavailableCode = "unavailable"
    static let endedTileHeight: CGFloat = 88

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
            .frame(height: Self.endedTileHeight)
            .frame(maxWidth: .infinity)
    }

    // MARK: frame

    private var frame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken)
            if case .done(let path) = state.phase, let img = ResultImageCache.image(path) {
                Image(nsImage: img).resizable().scaledToFill().transition(.opacity)
                    .generatedImageLabel(path: path, fallback: promptUsed)  // M9.T02 (NFR-A5)
                    .accessibilityIdentifier("imageJobCard.result")
            } else if state.isActive, let p = state.previewPath, let img = PreviewFrameCache.image(p) {
                Image(nsImage: img).resizable().interpolation(.medium).scaledToFill()
                    .id(p).transition(.opacity)
                    .accessibilityLabel(Text(CopyKey("img.preview.a11y")))  // M4 review P2-8
                    .accessibilityIdentifier("imageJobCard.preview")
            } else if state.isActive {
                DotMatrixPlaceholder(animated: !reduceMotion)
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
                                .accessibilityIdentifier("imageJobCard.cancel")
                        }
                    }
                    .padding(Spacing.space2)
                }
                .onAppear { onProgressShown?() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control) }
        .aspectRatio(state.aspect, contentMode: .fit)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state.previewPath)
    }

    // MARK: footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: Spacing.space2) {
            Text(statusText).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                .accessibilityIdentifier("imageJobCard.status")
            if state.lighterSetting {
                Text(CopyKey("model.lighterSetting")).typeStyle(.footnote).foregroundStyle(Color.textTertiary)
            }
            Spacer()
            if state.phase == .lost, let onRestart {
                // R-291 AC2: the line is the action (as `video.lost`): "Interrupted · Restart".
                Button(action: onRestart) { Text(CopyKey("job.interrupted")).typeStyle(.subhead) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("imageJobRestart")
            } else if isUnavailable {
                // The Photo pack is not ready on this Mac: the fix is in Settings › Capabilities, not a retry.
                Button { SettingsNavigator.shared.request(.capabilities); openSettings() } label: {
                    Text(CopyKey("img.needsLargerModel.cta"))
                }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityIdentifier("imageJobCard.openCapabilities")
            } else if let onRetry, state.phase == .lost || isFailed {
                Button(action: onRetry) { Text(CopyKey("msg.retry")) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("imageJobCard.retry")
            }
        }
    }

    /// `imageJobCard`, plus the ids the M4.T04 UI legs wait for (MediaJobUITests).
    var phaseID: String {
        switch state.phase {
        case .waiting: "imageJobWaiting"
        case .lost: "imageJobInterrupted"
        // R-285 AC6 (Q-015 r5): missing detectors run no job, so the repair card is not a job card.
        case .safetyMissing: "imageJobSafetyMissing"
        default: "imageJobCard"
        }
    }

    private var isFailed: Bool { if case .failed = state.phase { true } else { false } }
    private var isUnavailable: Bool { state.phase == .failed(code: Self.unavailableCode) }

    var statusText: String {
        switch state.phase {
        case .placeholder, .generating: CopyKey("img.creating").string()
        case .waiting(let position): position > 1
            ? CopyText(CopyKey("job.waitingPosition"), ["position": "\(position)"]).string : CopyKey("img.waiting").string()
        case .loading: CopyKey("img.loading").string()
        case .done: ""
        case .blocked, .safetyMissing: ""
        case .failed(let code) where code == Self.unavailableCode:
            CopyText(CopyKey("add.disabled.pack"), ["pack": CopyKey("onb.pack.photo.name").string()]).string
        case .failed: CopyKey("img.failed").string()  // VQ r65 (S-11): the picture's own line; [Retry] is beside it
        case .cancelled: CopyKey("img.cancelled").string()
        case .lost: onRestart == nil ? CopyKey("img.lost").string() : ""
        }
    }
}

/// `img.promptUsed` popover: the prompt, selectable, with Copy.
struct PromptUsedPopover: View {
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("img.promptUsed")).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
            Text(verbatim: prompt).typeStyle(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("imageJobCard.prompt")
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(prompt, forType: .string) } label: {
                Text(CopyKey("img.copy"))
            }
                .accessibilityIdentifier("img.copy")
            .controlSize(.small)
        }
        .padding(Spacing.space3)
        .frame(width: 320, alignment: .leading)
    }
}
