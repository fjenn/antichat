// M5.T12 step 1 (R-045 AC1, components §4 VideoPlayer: loading · playing · error; P-media-13 Apple AVKit): the clip in
// its result card. The poster first (written by the helper only after the gate allowed the clip) with a play button;
// play mounts an `AVPlayerView` (`controlsStyle = .inline`: play/pause and scrub; `showsFullScreenToggleButton`) over an
// `AVQueuePlayer`. Loop is on by default for clips ≤ 10 s (`AVPlayerLooper`); the clip starts muted when it has no
// sound track and unmuted when it has one. Loop, mute and Open in viewer sit on the frame (always in the
// accessibility tree, shown on hover/focus). Only gated, stored files reach this view.
import AntiChatDesign
import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// The player's starting state for a clip (pure; InlineVideoPlayerTests).
public struct VideoPlaybackDefaults: Sendable, Equatable {
    public var loops: Bool
    public var muted: Bool
    /// Clips up to this length loop by default (R-045 AC1).
    public static let loopLimit: Double = 10

    public init(loops: Bool, muted: Bool) {
        self.loops = loops
        self.muted = muted
    }

    public static func defaults(duration: Double, hasSound: Bool) -> VideoPlaybackDefaults {
        VideoPlaybackDefaults(loops: duration > 0 && duration <= loopLimit + 0.001, muted: !hasSound)
    }
}

/// One clip's player: an `AVQueuePlayer`, its looper while looping, and the facts the controls need.
@MainActor @Observable
public final class InlineVideoPlayerModel {
    public enum Phase: Equatable { case loading, ready, playing, error }

    public let url: URL
    public private(set) var phase: Phase = .loading
    public private(set) var duration: Double = 0
    public private(set) var hasSound = false
    public private(set) var loops = false
    public private(set) var isMuted = true
    /// True once the user pressed play (the poster gives way to the player view).
    public private(set) var started = false
    @ObservationIgnored public let player = AVQueuePlayer()
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var asset: AVURLAsset
    @ObservationIgnored private var loaded = false

    public init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
        player.actionAtItemEnd = .pause
    }

    /// Reads duration and tracks, then applies the defaults (once).
    public func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            let d = try await asset.load(.duration).seconds
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard try await asset.load(.isPlayable) else { phase = .error; return }
            duration = d.isFinite ? d : 0
            hasSound = !audio.isEmpty
            let defaults = VideoPlaybackDefaults.defaults(duration: duration, hasSound: hasSound)
            isMuted = defaults.muted
            player.isMuted = defaults.muted
            setLoops(defaults.loops)
            phase = .ready
        } catch {
            phase = .error
        }
    }

    public func setLoops(_ on: Bool) {
        loops = on
        let wasPlaying = player.rate > 0
        let time = player.currentTime()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        let item = AVPlayerItem(asset: asset)
        if on {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
        }
        if time.isValid, time.seconds > 0 { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        if wasPlaying { player.play() }
    }

    public func setMuted(_ on: Bool) {
        isMuted = on
        player.isMuted = on
    }

    public func play() {
        started = true
        if !loops, let item = player.currentItem, item.currentTime() >= item.duration, item.duration.isNumeric {
            player.seek(to: .zero)
        }
        player.play()
        phase = .playing
    }

    public func pause() {
        player.pause()
        if phase == .playing { phase = .ready }
    }

    public func togglePlay() { player.rate > 0 ? pause() : play() }

    /// Scrubs to `fraction` (0…1) of the clip.
    public func seek(fraction: Double) {
        guard duration > 0 else { return }
        let t = CMTime(seconds: max(0, min(1, fraction)) * duration, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// "0:04" (the duration badge; Library cells use it too).
    public static func durationLabel(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// `AVPlayerView` with inline controls and the full-screen toggle.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var controls: AVPlayerViewControlsStyle = .inline

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = controls
        v.showsFullScreenToggleButton = true
        v.videoGravity = .resizeAspect
        v.setAccessibilityIdentifier("videoPlayer.view")
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
        if v.controlsStyle != controls { v.controlsStyle = controls }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

public struct InlineVideoPlayer: View {
    @State private var model: InlineVideoPlayerModel
    let poster: String?
    let aspect: CGFloat
    let onExpand: (() -> Void)?
    @State private var hovering = false

    public init(url: URL, poster: String?, aspect: CGFloat, onExpand: (() -> Void)? = nil) {
        _model = State(initialValue: InlineVideoPlayerModel(url: url))
        self.poster = poster
        self.aspect = aspect
        self.onExpand = onExpand
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken)
            if model.started {
                AVPlayerViewRepresentable(player: model.player)
                    // Q-015 r5: AVPlayerView is an ignored AX container, so its `videoPlayer.view` id never reached
                    // accessibility clients (its controls were flattened into the card). One named group holds them.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("videoPlayer.view")
            } else {
                if let poster, let img = NSImage(contentsOfFile: poster) {
                    Image(nsImage: img).resizable().scaledToFill()
                        .accessibilityIdentifier("videoJob.poster")
                }
                Button { model.play() } label: {
                    Image(systemName: model.phase == .error ? "exclamationmark.triangle" : "play.fill")
                        .font(.system(size: 22)).foregroundStyle(Color.textPrimary)
                        .frame(width: 44, height: 44).background(Circle().fill(Color.surfaceRaised.opacity(0.9)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.phase == .error)
                .help(CopyKey("video.play").string())
                .accessibilityLabel(Text(CopyKey("video.play")))
                .accessibilityIdentifier("videoPlayer.play")
            }
            controls
                .padding(Spacing.space2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .opacity(hovering || !model.started ? 1 : 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control) }
        .aspectRatio(aspect, contentMode: .fit)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onExpand?() }
        .accessibilityAction(named: Text(CopyKey("video.expand"))) { onExpand?() }  // M9.T01: double-click to expand, for VO too
        .task { await model.load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("videoPlayer")
        .accessibilityValue(Text(verbatim: InlineVideoPlayerModel.durationLabel(model.duration)))
    }

    private var controls: some View {
        HStack(spacing: Spacing.space1) {
            chip(model.loops ? "repeat.circle.fill" : "repeat", CopyKey("video.loop"), id: "videoPlayer.loop",
                 selected: model.loops) { model.setLoops(!model.loops) }
            chip(model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                 CopyKey(model.isMuted ? "video.unmute" : "video.mute"), id: "videoPlayer.mute",
                 selected: !model.isMuted) { model.setMuted(!model.isMuted) }
            if let onExpand {
                chip("arrow.up.left.and.arrow.down.right", CopyKey("video.expand"), id: "videoPlayer.expand",
                     selected: false) { model.pause(); onExpand() }
            }
        }
    }

    private func chip(_ symbol: String, _ label: CopyKey, id: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.surfaceRaised.opacity(0.9)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label.string())
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
