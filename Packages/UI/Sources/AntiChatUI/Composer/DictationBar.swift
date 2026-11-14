// DictationBar (M3.T03 step 5; S-17, IS-9, components.md "DictationBar"; osaurus@2922745 VoiceInputOverlay /
// VoiceComponents as the design reference, nothing ported). It replaces the composer field while dictating:
//   [× cancel] [partial text, grey · or the level-reactive dots] [m:ss] [■ stop-to-review] [↑ send-now]
// The live partial streams in `text.secondary` and is handed to the field (`text.primary`) at final. The dots follow
// the input level (30 Hz); with Reduce Motion they stay still and only their opacity follows the level. Finalizing
// dims ■ / ↑ and shows the last partial. Accessibility ids: `dictation.cancel`, `dictation.waveform` (value = level
// updates, AT-050 AC1), `dictation.elapsed`, `dictation.partial`, `dictation.stop`, `dictation.send`.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import SwiftUI

struct DictationBar: View {
    @Environment(\.accentPreset) private var accentPreset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let dictation: DictationController

    private var finalizing: Bool { dictation.phase == .finalizing }

    var body: some View {
        HStack(spacing: Spacing.space2) {
            ComposerIconButton(symbol: "xmark", help: CopyText(CopyKey("dictation.cancel"))) { dictation.stop(.cancel) }
                .accessibilityIdentifier("dictation.cancel")
            ZStack(alignment: .leading) {
                if dictation.partial.isEmpty {
                    LevelDots(levels: dictation.levels, reduceMotion: reduceMotion, tint: accentPreset.color)
                } else {
                    Text(verbatim: dictation.partial)
                        .typeStyle(.body)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .accessibilityIdentifier("dictation.partial")
                }
            }
            .frame(maxWidth: .infinity, minHeight: SendStopButton.diameter, alignment: .leading)
            // Q-015 r3: one element whose label is the last partial, else "Recording". A `.contain` container exposes
            // no AX value, so VoiceOver never heard "Recording" and the level probe always read "".
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(dictation.partial.isEmpty ? Text(CopyKey("a11y.dictation.recording")) : Text(verbatim: dictation.partial))
            .accessibilityAddTraits(.isStaticText)  // a text-like element exposes its value (an AXUnknown group did not)
            .accessibilityIdentifier("dictation.waveform")
            // M3 review P2-4: VoiceOver hears "Recording"; the level-update count (AT-050 AC1's waveform probe) is the
            // value only in automated runs (never in Release).
            .accessibilityValue(LaunchOptions.current.isAutomationRun ? Text(verbatim: "\(dictation.levelUpdates)") : Text(verbatim: ""))
            if dictation.isBasic { BasicVoiceLabel() }  // M3.T04 (R-281 AC1)
            // vq/voice-mac-capture (S-17): finalizing showed only dimmed controls; a spinner takes the timer's place.
            if finalizing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(Text(CopyKey("status.thinking")))
                    .accessibilityIdentifier("dictation.finalizing")
            } else {
                Elapsed(since: dictation.startedAt)
            }
            // The stop square in the primary text colour (grey on the grey bar read as disabled; S-17).
            ComposerIconButton(symbol: "stop.fill", help: CopyText(CopyKey("dictation.stop")), tint: .textPrimary) {
                dictation.stop(.review)
            }
                .disabled(finalizing)
                .accessibilityIdentifier("dictation.stop")
            Button { dictation.stop(.sendNow) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.buttonPrimaryFg)
                    .frame(width: SendStopButton.diameter, height: SendStopButton.diameter)
                    .background(Circle().fill(Color.sendBg.opacity(finalizing ? 0.4 : 1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(finalizing)
            .help(CopyText(CopyKey("dictation.send")).string)
            .accessibilityLabel(Text(CopyKey("dictation.send")))
            .accessibilityIdentifier("dictation.send")
        }
        .frame(minHeight: SendStopButton.diameter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictationBar")
    }
}

/// Level-reactive dots: height follows each level (−60…−10 dBFS → 4…20 pt); Reduce Motion → fixed dots whose
/// opacity follows the level.
struct LevelDots: View {
    let levels: [Float]
    let reduceMotion: Bool
    let tint: Color
    static let count = DictationController.waveformCount

    static func fraction(_ dB: Float) -> CGFloat { CGFloat(min(1, max(0, (dB + 60) / 50))) }

    var body: some View {
        let padded = Array(repeating: Float(-100), count: max(0, Self.count - levels.count)) + levels.suffix(Self.count)
        HStack(alignment: .center, spacing: 3) {
            ForEach(padded.indices, id: \.self) { i in
                let f = Self.fraction(padded[i])
                Capsule()
                    .fill(tint.opacity(reduceMotion ? 0.25 + 0.75 * f : 0.85))
                    .frame(width: 3, height: reduceMotion ? 4 : 4 + 16 * f)
            }
        }
        .frame(height: 20)
        .animation(reduceMotion ? nil : .linear(duration: 1.0 / 30), value: levels)
        .accessibilityHidden(true)
    }
}

/// `m:ss` since the bar appeared.
struct Elapsed: View {
    let since: Date?

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    var body: some View {
        TimelineView(.periodic(from: since ?? .now, by: 1)) { ctx in
            Text(verbatim: Self.format(ctx.date.timeIntervalSince(since ?? ctx.date)))
                .typeStyle(.callout)
                .monospacedDigit()
                .foregroundStyle(Color.textSecondary)
        }
        .accessibilityIdentifier("dictation.elapsed")
    }
}
