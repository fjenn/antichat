// VoiceOverlay (M3.T11 step 1–2; S-16, IS-9, components.md "VoiceOverlay"; design reference: the ChatGPT voice mode
// orb — nothing copied). It sits above the composer in the same chat while a conversation runs:
//   [orb]  [caption: partial transcript while the user speaks · the sentence being spoken]
//   [mic mute] [speaker mute] [× End]
// The composer stays usable: a typed message during the session is a normal turn whose reply is spoken too.
// States: connecting (`voice.connecting`) → listening (`voice.listening`, orb follows the input level) → user speaking →
// thinking → speaking (orb breathes with the speech) → barge-in (snaps to listening in the update that reports it) →
// muted → error (`voice.noDevice` + [Sound settings] [Type instead]). Accessibility ids: `voiceOverlay`, `voice.orb` (value = phase),
// `voice.caption`, `voice.muteMic`, `voice.muteSpeaker`, `voice.end`.
import AntiChatDesign
import AntiChatHarness
import AntiChatPlatform
import AppKit
import QuartzCore
import SwiftUI

struct VoiceOverlay: View {
    @Environment(\.accentPreset) private var accentPreset
    @EffectiveReduceMotion private var reduceMotion
    let voice: VoiceSessionController
    /// VQ-M10 round 65 (S-16): inside the composer's own card (above its text row) instead of a second rounded strip
    /// stacked on the composer: one surface, as the reference's voice bar.
    var embedded = false
    /// vq/voice-mac-capture (S-16): "Type instead" on an error ends the call and hands the focus to the composer.
    var onTypeInstead: (() -> Void)? = nil
    @State private var ptt = PushToTalkMonitor()
    /// M3.T12: the half-duplex hint was shown and went (once per session; the overlay lives as long as the call).
    @State private var hintDone = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            controls
            if voice.halfDuplex, !hintDone {
                HeadphonesHint { hintDone = true }
                    .padding(.leading, VoiceOrb.size + Spacing.space3)
            }
        }
        .padding(.horizontal, embedded ? 0 : Spacing.space3)
        .padding(.vertical, embedded ? 0 : Spacing.space2)
        .background {
            if !embedded { RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Color.surfaceSunken) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voiceOverlay")
        // M9.T01: the mode, spoken when VoiceOver enters the overlay. Q-015 r3: as the label — a `.contain` group
        // exposes no AX value, so the value was never read out (or seen by tests).
        .accessibilityLabel(Text(CopyKey(voice.mode == .pushToTalk ? "set.voice.pushToTalk" : "set.voice.handsFree")))
        .onAppear { if voice.mode == .pushToTalk { ptt.install(voice) } }
        .onDisappear { ptt.remove() }
        // M3 review P2-4: VoiceOver is told when the call is ready, when it fell back to half duplex and when it failed.
        .onChange(of: voice.halfDuplex) { _, on in
            if on { Self.announce(CopyText(CopyKey("voice.headphones")).string) }
        }
        .onChange(of: voice.phase) { old, new in
            if old == .connecting, new == .listening { Self.announce(CopyText(CopyKey("voice.listening")).string) }
            if case .error = new, !old.isError { Self.announce(captionText) }
        }
    }

    static func announce(_ text: String) {
        StreamAnnouncer.systemPost(StreamAnnouncer.Announcement(text: text, priority: .standard))
    }

    private var controls: some View {
        HStack(spacing: Spacing.space3) {
            VoiceOrb(phase: voice.phase, level: voice.inputLevel, tint: accentPreset.color, reduceMotion: reduceMotion)
                .frame(width: VoiceOrb.size, height: VoiceOrb.size)
            HStack(spacing: Spacing.space2) {
                CaptionsView(text: captionText, secondary: voice.phase != .speaking)
                // vq/voice-mac-capture (S-16, IS-2): thinking was a blank strip; the reference shows a working
                // indicator beside the state's word, so the user knows the answer is on its way.
                if voice.phase == .thinking, voice.caption.isEmpty { ThinkingDots(animated: !reduceMotion) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .error(let key) = voice.phase {
                errorActions(key)
            } else {
                ComposerIconButton(symbol: voice.micMuted ? "mic.slash.fill" : "mic.fill",
                                   help: CopyText(CopyKey(voice.micMuted ? "voice.unmuteMic" : "voice.muteMic")), isOn: voice.micMuted) {
                    voice.toggleMic()
                }
                .accessibilityIdentifier("voice.muteMic")
                .accessibilityValue(voice.micMuted ? Text(CopyKey("voice.micMuted")) : Text(verbatim: ""))  // M9.T01: spoken, localised
                ComposerIconButton(symbol: voice.speakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   help: CopyText(CopyKey(voice.speakerMuted ? "voice.unmuteSpeaker" : "voice.muteSpeaker")), isOn: voice.speakerMuted) {
                    voice.toggleSpeaker()
                }
                .accessibilityIdentifier("voice.muteSpeaker")
                .accessibilityValue(voice.speakerMuted ? Text(CopyKey("voice.speakerMuted")) : Text(verbatim: ""))
                ComposerIconButton(symbol: "xmark", help: CopyText(CopyKey("voice.end"))) { voice.end() }
                    .accessibilityIdentifier("voice.end")
            }
        }
    }

    /// vq/voice-mac-capture (S-16, IS-10): an error offers its fix where it happened — no microphone → the system's
    /// Sound settings (input devices); microphone access off → System Settings; every error → Type instead (ends the
    /// call, the composer takes the focus). Before, "No microphone found" offered only End.
    @ViewBuilder private func errorActions(_ key: String) -> some View {
        if key == "voice.denied" {
            Button { PermissionCenter.shared.openSystemSettings(.microphone) } label: { Text(CopyKey("perm.openSettings")) }
                .buttonStyle(VoiceSecondaryButtonStyle())
                .accessibilityIdentifier("voice.openSettings")
        } else if key == "voice.noDevice" || !key.hasPrefix("voice.") {
            Button { Self.openSoundInput() } label: { Text(CopyKey("voice.soundSettings")) }
                .buttonStyle(VoiceSecondaryButtonStyle())  // round 65 S-16: was a pale accent label on grey
                .accessibilityIdentifier("voice.soundSettings")
        }
        Button {
            voice.dismissError()
            onTypeInstead?()
        } label: { Text(CopyKey("voice.typeInstead")) }
            .buttonStyle(PrimaryButtonStyle())
            .controlSize(.small)
            .accessibilityIdentifier("voice.end")
    }

    /// System Settings › Sound, input devices (where a microphone is picked or shows up once plugged in).
    static let soundInputURL = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!

    static func openSoundInput() { NSWorkspace.shared.open(soundInputURL) }

    /// The caption line: the live text, else the state's word (connecting / listening / muted / error).
    private var captionText: String {
        if case .error(let key) = voice.phase {
            // Q-015 r3: an error code without copy (`voice.unavailable`) showed the raw code; it gets the generic line.
            if key.hasPrefix("voice.") { return CopyKey(key).isKnown ? CopyText(CopyKey(key)).string : CopyText(CopyKey("engine.error")).string }
            return CopyText(CopyKey("voice.noDevice")).string
        }
        if !voice.caption.isEmpty { return voice.caption }
        switch voice.phase {
        case .connecting: return CopyText(CopyKey("voice.connecting")).string
        case .listening, .userSpeaking:
            return voice.micMuted ? CopyText(CopyKey("voice.micMuted")).string : CopyText(CopyKey("voice.listening")).string
        case .speaking where voice.speakerMuted: return CopyText(CopyKey("voice.speakerMuted")).string
        case .thinking: return CopyText(CopyKey("status.thinking")).string
        default: return ""
        }
    }
}

/// Three dots that light up in turn (the working glyph beside "Thinking…"); Reduce Motion → static dots.
/// Core Animation, not a SwiftUI repeatForever (the selection-hang rule, see PendingDot).
struct ThinkingDots: View {
    let animated: Bool

    var body: some View {
        ThinkingDotsLayer(animated: animated)
            .frame(width: 22, height: 6)
            .accessibilityHidden(true)
    }
}

struct ThinkingDotsLayer: NSViewRepresentable {
    let animated: Bool

    func makeNSView(context: Context) -> DotsView { DotsView() }

    func updateNSView(_ v: DotsView, context: Context) {
        if v.animated != animated { v.animated = animated }
    }

    final class DotsView: NSView {
        static let key = "thinkingDots"
        let dots = (0..<3).map { _ in CALayer() }
        var animated = true { didSet { apply() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            dots.forEach { layer?.addSublayer($0) }
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var color = NSColor.secondaryLabelColor.cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.textSecondary.cgColor }
            dots.forEach { $0.backgroundColor = color }
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = min(bounds.height, bounds.width / 4)
            let gap = (bounds.width - 3 * side) / 2
            for (i, d) in dots.enumerated() {
                d.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                d.cornerRadius = side / 2
                d.position = CGPoint(x: side / 2 + CGFloat(i) * (side + gap), y: bounds.midY)
            }
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            let now = CACurrentMediaTime()
            for (i, d) in dots.enumerated() {
                d.removeAnimation(forKey: Self.key)
                // Static (Reduce Motion, snapshots): a fading row, so the glyph still reads as "working".
                d.opacity = animated ? 0.3 : Float(1 - 0.3 * Double(i))
                guard animated, window != nil else { continue }
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0.3
                a.toValue = 1
                a.duration = 0.45
                a.autoreverses = true
                a.repeatCount = .infinity
                a.beginTime = now + Double(i) * 0.18
                a.fillMode = .backwards
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.isRemovedOnCompletion = false
                d.add(a, forKey: Self.key)
            }
        }
    }
}

/// The live caption (R-052 AC5): one or two lines, the newest words kept visible.
struct CaptionsView: View {
    let text: String
    let secondary: Bool

    var body: some View {
        Text(verbatim: text)
            .typeStyle(.body)
            .foregroundStyle(secondary ? Color.textSecondary : Color.textPrimary)
            .lineLimit(2)
            .truncationMode(.head)
            .animation(nil, value: text)
            .accessibilityIdentifier("voice.caption")
            .accessibilityValue(Text(verbatim: text))
    }
}

/// The orb (VQ-M10 round 65, S-16: each state has its own look, not only its own motion — the blind panel saw the
/// same blue dot in every capture):
///   connecting   a grey dashed ring around a dim grey orb
///   listening    the accent orb with a live level meter (four white bars that rise with the input level; dots in
///                silence)
///   user speaking  the same meter, plus an accent halo (it is hearing you)
///   thinking     a grey orb with an accent arc around it
///   speaking     the accent orb with a waveform glyph and the halo; the orb breathes with the speech
///   error        a red orb with a crossed-out microphone
/// The motion runs as Core Animation layer animations (VoiceOrbLayer), not a 60 fps SwiftUI TimelineView: a frame clock
/// in the window re-ran SwiftUI transactions every display frame for the whole call (the transcript's selection-hang
/// pattern; Q-015 r5, fix/selection-hang follow-up). Reduce Motion: the same looks, static.
struct VoiceOrb: View {
    static let size: CGFloat = 40
    let phase: VoiceSessionController.Phase
    let level: Float
    let tint: Color
    let reduceMotion: Bool

    static func levelFraction(_ dB: Float) -> CGFloat { CGFloat(min(1, max(0, (dB + 60) / 45))) }

    /// The meter's bar heights (fraction of the orb) for an input level: dots in silence, up to 0.5 of the orb.
    static func meter(_ level: CGFloat) -> [CGFloat] {
        [0.55, 1, 0.8, 0.45].map { 0.12 + 0.38 * level * $0 }
    }

    /// The speaking glyph: a fixed waveform (the orb's breathing carries the motion).
    static let waveform: [CGFloat] = [0.22, 0.42, 0.58, 0.36, 0.2]

    private var isAccent: Bool {
        switch phase {
        case .listening, .userSpeaking, .speaking: true
        default: false
        }
    }

    private var fill: Color {
        switch phase {
        case .error: .danger
        case .listening, .userSpeaking, .speaking: tint
        default: .textTertiary
        }
    }

    var body: some View {
        ZStack {
            if phase == .userSpeaking || phase == .speaking {
                Circle().stroke(tint.opacity(0.35), lineWidth: 2)  // the halo
            }
            Group {
                if reduceMotion {
                    Circle().fill(fill.opacity(staticOpacity))
                } else {
                    VoiceOrbLayer(motion: Self.motion(phase, level: level), tint: NSColor(fill))
                }
            }
            .padding(4)
            glyph
            if phase == .thinking {
                Circle().trim(from: 0, to: 0.3)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if phase == .connecting {
                Circle().strokeBorder(Color.textTertiary, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
        .accessibilityElement()
        .accessibilityIdentifier("voice.orb")
        .accessibilityLabel(Text(CopyKey(Self.phaseKey(phase))))  // M9.T01: what the conversation is doing, localised
    }

    @ViewBuilder private var glyph: some View {
        switch phase {
        case .listening, .userSpeaking:
            bars(Self.meter(phase == .userSpeaking ? max(0.25, Self.levelFraction(level)) : Self.levelFraction(level)))
        case .speaking:
            bars(Self.waveform)
        case .error:
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
        default:
            EmptyView()
        }
    }

    private func bars(_ heights: [CGFloat]) -> some View {
        let side = Self.size - 8
        return HStack(spacing: 2.5) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().fill(Color.white.opacity(0.95))
                    .frame(width: 3, height: max(3, side * heights[i]))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: heights)
        .accessibilityHidden(true)
    }

    static func phaseKey(_ p: VoiceSessionController.Phase) -> String {
        switch p {
        case .connecting: "voice.connecting"
        case .thinking: "a11y.voice.thinking"
        case .speaking: "a11y.voice.speaking"
        default: "voice.listening"
        }
    }

    private var staticOpacity: Double {
        switch phase {
        case .connecting: 0.35
        case .listening, .userSpeaking: 0.85 + 0.15 * Double(Self.levelFraction(level))
        case .thinking: 0.7
        case .speaking: 1
        case .error: 1
        case .idle: 0.25
        }
    }

    /// The orb's motion per phase (the former per-frame `scale(t)`: same periods; the fill stays large enough to hold
    /// the meter).
    static func motion(_ phase: VoiceSessionController.Phase, level: Float) -> VoiceOrbLayer.Motion {
        switch phase {
        case .listening, .userSpeaking: .level(0.86 + 0.14 * levelFraction(level))
        case .thinking: .pulse(low: 0.8, high: 0.9, period: 2 * .pi / 2.4, opacity: 1)
        case .speaking: .pulse(low: 0.9, high: 1.0, period: .pi / 6.3, opacity: 1)
        case .connecting: .pulse(low: 0.66, high: 0.74, period: 2 * .pi / 3, opacity: 0.45)
        case .error: .level(1)
        case .idle: .level(0.7)
        }
    }
}

/// VQ-M10 round 65 (S-16): the voice bar's secondary action (Sound settings / Open Settings): a neutral outlined pill
/// with the primary text colour (the platform's small bordered button drew a pale accent label on grey).
struct VoiceSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.textPrimary.opacity(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control))
            .contentShape(Capsule())
    }
}

/// The orb as a radial-gradient layer whose scale is either set (the input level) or a repeating Core Animation pulse.
struct VoiceOrbLayer: NSViewRepresentable {
    enum Motion: Equatable {
        case level(CGFloat)
        case pulse(low: CGFloat, high: CGFloat, period: Double, opacity: Float)
    }

    let motion: Motion
    let tint: NSColor

    func makeNSView(context: Context) -> OrbView { OrbView() }

    func updateNSView(_ v: OrbView, context: Context) {
        if v.tint != tint { v.tint = tint }
        if v.motion != motion { v.motion = motion }
    }

    final class OrbView: NSView {
        static let key = "orbPulse"
        let orb = CAGradientLayer()
        var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
        var motion: Motion = .level(0.7) { didSet { apply() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            orb.type = .radial
            orb.startPoint = CGPoint(x: 0.5, y: 0.5)
            orb.endPoint = CGPoint(x: 1, y: 1)
            orb.masksToBounds = true
            layer?.addSublayer(orb)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            var colors: [CGColor] = []
            effectiveAppearance.performAsCurrentDrawingAppearance {
                colors = [tint.withAlphaComponent(0.95).cgColor, tint.withAlphaComponent(0.55).cgColor]
            }
            orb.colors = colors
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = min(bounds.width, bounds.height)
            orb.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            orb.cornerRadius = side / 2
            orb.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard window != nil else {
                orb.removeAnimation(forKey: Self.key)
                return
            }
            switch motion {
            case .level(let s):
                orb.removeAnimation(forKey: Self.key)
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.08)  // smooths the level steps (the meter updates ~20×/s)
                orb.transform = CATransform3DMakeScale(s, s, 1)
                orb.opacity = 1
                CATransaction.commit()
            case .pulse(let low, let high, let period, let opacity):
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                orb.transform = CATransform3DMakeScale((low + high) / 2, (low + high) / 2, 1)
                orb.opacity = opacity
                CATransaction.commit()
                let a = CABasicAnimation(keyPath: "transform.scale")
                a.fromValue = low
                a.toValue = high
                a.duration = period / 2
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.isRemovedOnCompletion = false
                orb.add(a, forKey: Self.key)
            }
        }
    }
}

/// Push-to-talk (M3.T11 step 3, R-052 AC2): Space held while this window is key and no text field is first responder →
/// `pttDown` / `pttUp`. Installed only while a push-to-talk conversation runs; Space typed into the composer stays text.
/// M3 review P2-7: once Space is down, its key-up ends the turn wherever it lands, and a window that loses key (⌘-Tab,
/// a click elsewhere) or an app that goes inactive while Space is held ends it too (that key-up never reaches us).
@MainActor
final class PushToTalkMonitor {
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    func install(_ voice: VoiceSessionController) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak voice] event in
            guard let voice, voice.mode == .pushToTalk, event.keyCode == 49 else { return event }
            if event.type == .keyUp, voice.isPushToTalkHeld {
                voice.pttUp()
                return nil
            }
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let window = event.window, window.isKeyWindow,
                  !(window.firstResponder is NSText) else { return event }
            if event.type == .keyDown {
                if !event.isARepeat { voice.pttDown() }
            } else {
                voice.pttUp()
            }
            return nil
        }
        let release: @Sendable (Notification) -> Void = { [weak voice] _ in
            MainActor.assumeIsolated { voice?.releasePushToTalk() }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main, using: release),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: release),
        ]
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
