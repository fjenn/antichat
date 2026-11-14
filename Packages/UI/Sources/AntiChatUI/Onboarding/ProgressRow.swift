// M2.T20 step 1 (S-04 ProgressRow; components.md): one chosen pack (or the Evil row) on the light step-4 panel — icon,
// name, verb line, the pack-colour bar and its state: Waiting / n % / Checking / Ready / Paused — no internet / Didn't
// finish. Retry (`onb.4.row.*`). The bar fills with the bytes in; Ready shows a check.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct ProgressRow: View {
    let row: SetupProgress.Row
    var onRetry: (() -> Void)?

    private var pack: ModelPack? { ModelPack(rawValue: row.group) }
    private var isEvil: Bool { row.group == "evil" }

    private var tint: Color {
        switch pack {
        case .chat: .packChat
        case .voice: .packVoice
        case .photo: .packPhoto
        case .video: .packVideo
        case nil: .evilBase
        }
    }

    private var fraction: Double {
        switch row.state {
        case .ready, .checking: 1
        case .waiting: 0
        default: row.bytesTotal > 0 ? min(1, Double(row.bytesDone) / Double(row.bytesTotal)) : 0
        }
    }

    var stateText: CopyText {
        switch row.state {
        case .waiting: CopyText(CopyKey("onb.4.row.waiting"))
        case .downloading(let p): CopyText(CopyKey("onb.4.row.downloading"), ["percent": String(p)])
        case .checking: CopyText(CopyKey("onb.4.row.checking"))
        case .ready: CopyText(CopyKey("onb.4.row.ready"))
        case .paused: CopyText(CopyKey("onb.4.row.paused"))
        case .failed: CopyText(CopyKey("onb.4.row.failed"))
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(CopyKey(isEvil ? "onb.4.row.evil" : "onb.pack.\(row.group).name"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.textPrimary)
                        if !isEvil {
                            Text(CopyKey("onb.pack.\(row.group).verb"))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.onbPanelTextSecondary)
                        }
                    }
                    Spacer(minLength: 12)
                    stateLabel
                }
                bar
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onb.4.row.\(row.group)")
    }

    /// M10 visual QA (S-04): the same illustrated pack art as step 2 (the Evil row: the devil).
    private var icon: some View { PackIllustration(pack: pack, size: 40) }

    @ViewBuilder private var stateLabel: some View {
        switch row.state {
        case .failed:
            Button { onRetry?() } label: {
                Label { Text(stateText) } icon: { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.danger)
            .accessibilityIdentifier("onb.4.retry.\(row.group)")
        case .ready:
            Label { Text(stateText) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.onbChipOkFg) }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
        default:
            Text(stateText)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(row.state == .paused ? Color.warning : Color.onbPanelTextSecondary)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.08))
                Capsule().fill(tint).frame(width: max(fraction > 0 ? 6 : 0, geo.size.width * fraction))
                    .opacity(row.state == .paused || row.state == .failed ? 0.45 : 1)
            }
        }
        .frame(height: 6)
        .animation(.smooth(duration: 0.3), value: fraction)
        .accessibilityHidden(true)
    }
}
