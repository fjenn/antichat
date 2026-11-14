// SendStopButton (components.md §2; M1.T08 step 3): one circle at the composer's right end, accessibility id
// `voiceOrSend`. Empty → Send, pale and disabled (M9.T08: the spoken conversation has its own composer button since
// M3.T11, so the empty state no longer doubles it with a disabled waveform); with content → Send;
// generating → Stop in the same position (NFR-U2); stopping → Stop dimmed; queued → clock (NFR-U3).
import AntiChatDesign
import SwiftUI

struct SendStopButton: View {
    let state: ComposerModel.TrailingButton
    let mode: ComposerChatMode
    let queuedPercent: Int?
    let onSend: () -> Void
    let onStop: () -> Void

    static let diameter: CGFloat = 32

    /// Ids shared with T06's J02 tests: `voiceOrSend` (voice / send) and `stop` (Stop, same position).
    static func identifier(for state: ComposerModel.TrailingButton) -> String {
        switch state {
        case .stop, .stopping: "stop"
        default: "voiceOrSend"
        }
    }

    @State private var hovering = false

    private var isEnabled: Bool {
        switch state {
        case .voice, .stopping: false
        case .send(let enabled): enabled
        case .queuedSend, .stop: true
        }
    }

    /// Filled for an actionable send/stop; pale when disabled (ChatGPT "pale/disabled while empty").
    private var fill: Color {
        let base: Color = mode == .evil ? .evilBase : .sendBg
        return isEnabled ? base : base.opacity(0.18)
    }

    private var glyphColor: Color {
        guard isEnabled else { return .textDisabled }
        return mode == .evil ? .evilOnBase : .buttonPrimaryFg
    }

    private var symbol: String {
        switch state {
        case .voice, .send: "arrow.up"  // M9.T08: empty = disabled Send (components.md); voice has its own button
        case .queuedSend: "clock"
        case .stop, .stopping: "stop.fill"
        }
    }

    /// VoiceOver label (M9.md T01 step 2); the tooltip text with the shortcut becomes the hint.
    var accessibilityLabel: CopyText {
        switch state {
        case .voice, .send, .queuedSend: CopyText(CopyKey("a11y.send"))
        case .stop, .stopping: CopyText(CopyKey("a11y.stop"))
        }
    }

    var label: CopyText {
        switch state {
        case .voice, .send, .queuedSend: CopyText(CopyKey("tip.send"))
        case .stop, .stopping: CopyText(CopyKey("tip.stop"))
        }
    }

    /// The tooltip: the action, or why it is disabled (components.md universal "disabled": say why).
    private var help: String {
        switch state {
        case .queuedSend:
            if let queuedPercent { CopyText(CopyKey("composer.queuedPct"), ["percent": "\(queuedPercent)"]).string }
            else { CopyText(CopyKey("composer.queued")).string }
        default: label.string
        }
    }

    var body: some View {
        Button {
            switch state {
            case .stop: onStop()
            case .send, .queuedSend: onSend()
            case .voice, .stopping: break
            }
        } label: {
            ZStack {
                Circle().fill(fill)
                if hovering && isEnabled {
                    Circle().fill(Color.surfaceHover)
                }
                Image(systemName: symbol)
                    .font(.system(size: state == .stop || state == .stopping ? 12 : 15, weight: .semibold))
                    .foregroundStyle(glyphColor)
                    .contentTransition(.identity)  // same frame as the send (NFR-U2): no symbol animation
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityIdentifier(Self.identifier(for: state))
        .accessibilityLabel(Text(accessibilityLabel))  // M9.T01: "Send message" / "Stop generating"
        .accessibilityHint(isEnabled ? Text(label) : Text(verbatim: help))
        .animation(nil, value: state)
    }
}

#Preview("SendStopButton") {
    HStack(spacing: Spacing.space3) {
        SendStopButton(state: .voice, mode: .normal, queuedPercent: nil, onSend: {}, onStop: {})
        SendStopButton(state: .send(enabled: false), mode: .normal, queuedPercent: nil, onSend: {}, onStop: {})
        SendStopButton(state: .send(enabled: true), mode: .normal, queuedPercent: nil, onSend: {}, onStop: {})
        SendStopButton(state: .queuedSend, mode: .normal, queuedPercent: 42, onSend: {}, onStop: {})
        SendStopButton(state: .stop, mode: .normal, queuedPercent: nil, onSend: {}, onStop: {})
        SendStopButton(state: .send(enabled: true), mode: .evil, queuedPercent: nil, onSend: {}, onStop: {})
    }
    .padding(Spacing.space6)
    .background(Color.surfaceSunken)
}
