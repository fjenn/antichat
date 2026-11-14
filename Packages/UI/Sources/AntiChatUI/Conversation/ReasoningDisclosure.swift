// ReasoningDisclosure (components.md §3; M1.T15 step 2, R-007; P-shell-04 renderer for the expanded text).
// Reference behaviour (interaction-specs IS-2/IS-4, ux-principles P3/P12): ChatGPT shows nothing for short thinking;
// Claude narrates longer work as one activity line with seconds that collapses into a summary. So:
//   - while the model thinks (reasoning arrived, no answer yet) the PendingDot stays alone for the first 2 s — no
//     line for short thinking — then "Thinking… N s" (`status.thinkingFor`) with N = whole seconds since the send,
//     ticking each second;
//   - once the answer starts (or the turn ends) the line collapses to "Thought for N s ▸" (`status.thought`), N =
//     the reasoning's own duration (first → last reasoning token; stored as `provenance_json.reasoning_ms`). Thinking
//     shorter than the 2 s threshold leaves nothing behind (the line never appeared);
//   - the line is a disclosure: a click expands the reasoning as dimmed text (`text.secondary`, a leading rule),
//     also while it streams; a reply with reasoning but no timing (imported thinking blocks) shows `status.thoughtUntimed`.
// `ReasoningLineModel` is the pure part (tested on a virtual clock); the view recomputes it on a 4 Hz timeline.
import AntiChatDesign
import SwiftUI

public enum ReasoningLine: Equatable, Sendable {
    /// No reasoning, or thinking shorter than the threshold that is over.
    case none
    /// Thinking, under the threshold: the PendingDot alone.
    case pendingDot
    /// "Thinking… N s" (live).
    case thinking(seconds: Int)
    /// "Thought for N s ▸" (collapsed summary).
    case thought(seconds: Int)
    /// Reasoning without a measured duration (imports).
    case thoughtUntimed

    public var copyKey: String? {
        switch self {
        case .none, .pendingDot: nil
        case .thinking: "status.thinkingFor"
        case .thought: "status.thought"
        case .thoughtUntimed: "status.thoughtUntimed"
        }
    }

    public var seconds: Int? {
        switch self {
        case .thinking(let s), .thought(let s): s
        default: nil
        }
    }
}

public enum ReasoningLineModel {
    /// No line before 2 s (R-007 AC2; ChatGPT hides short thinking).
    public static let threshold: Double = 2

    /// - Parameters:
    ///   - hasReasoning: reasoning text arrived for this reply.
    ///   - thinking: the model is still thinking (turn running, no answer text yet).
    ///   - sinceSend: seconds since the send (live counter).
    ///   - thoughtSeconds: the finished reasoning's duration, if measured.
    public static func line(hasReasoning: Bool, thinking: Bool, sinceSend: Double, thoughtSeconds: Double?) -> ReasoningLine {
        guard hasReasoning else { return .none }
        if thinking {
            return sinceSend < threshold ? .pendingDot : .thinking(seconds: Int(sinceSend))
        }
        guard let s = thoughtSeconds else { return .thoughtUntimed }
        return s < threshold ? .none : .thought(seconds: max(Int(threshold), Int(s.rounded())))
    }
}

public struct ReasoningDisclosure: View {
    let reasoning: String
    let thinking: Bool
    let sentAt: Date
    let thoughtSeconds: Double?
    @State private var expanded: Bool
    @EffectiveReduceMotion private var reduceMotion

    public init(reasoning: String, thinking: Bool, sentAt: Date?, thoughtSeconds: Double?, expanded: Bool = false) {
        self.reasoning = reasoning
        self.thinking = thinking
        self.sentAt = sentAt ?? .distantPast
        self.thoughtSeconds = thoughtSeconds
        _expanded = State(initialValue: expanded)
    }

    public var body: some View {
        if thinking {
            // The line changes at the 2 s threshold and then once a second ("Thinking… N s"); a 0.25 s periodic
            // timeline updated the window's graph continuously while the model thought (fix/selection-hang).
            TimelineView(Self.schedule(sentAt: sentAt)) { context in
                content(line(at: context.date))
            }
        } else {
            content(line(at: Date()))
        }
    }

    /// Now, then the threshold, then every whole second after the send.
    static func schedule(sentAt: Date) -> StepSchedule {
        StepSchedule { d in
            let since = d.timeIntervalSince(sentAt)
            return sentAt.addingTimeInterval(max(ReasoningLineModel.threshold, since.rounded(.down) + 1))
        }
    }

    func line(at now: Date) -> ReasoningLine {
        ReasoningLineModel.line(hasReasoning: !reasoning.isEmpty, thinking: thinking,
                                sinceSend: max(0, now.timeIntervalSince(sentAt)), thoughtSeconds: thoughtSeconds)
    }

    @ViewBuilder
    private func content(_ line: ReasoningLine) -> some View {
        switch line {
        case .none:
            EmptyView()
        case .pendingDot:
            PendingDot().frame(minHeight: 24, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Button {
                    withAnimation(MotionToken.fast.animation(reduceMotion: reduceMotion)) { expanded.toggle() }
                } label: {
                    HStack(spacing: Spacing.space1) {
                        Text(label(line))
                            .typeStyle(.subhead)
                            .foregroundStyle(Color.textSecondary)
                            .contentTransition(.numericText())
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .probeID("reasoningLine")
                .accessibilityValue(Text(verbatim: expanded ? "expanded" : "collapsed"))
                .frame(minHeight: 24, alignment: .leading)
                if expanded {
                    Text(verbatim: reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                        .typeStyle(.body)
                        .foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Spacing.space3)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.borderSubtle).frame(width: 2)
                        }
                        .probeID("reasoningText")
                        .transition(.opacity)
                }
            }
        }
    }

    private func label(_ line: ReasoningLine) -> String {
        guard let key = line.copyKey else { return "" }
        return CopyKey(key).string(line.seconds.map { ["seconds": "\($0)"] } ?? [:])
    }
}
