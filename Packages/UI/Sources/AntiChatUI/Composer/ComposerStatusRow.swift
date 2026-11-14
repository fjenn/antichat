// ComposerStatusRow (M1.T08 step 7; IS-6 "a status row under the composer can show what will happen", F-384):
// project and mode chips, from `chat.project_id` and `chat.mode`. Empty in M1 unless a fixture sets them; renders
// nothing when there is no chip. Tool chips (T17) and the model/effort line join this row later.
import AntiChatDesign
import SwiftUI

struct ComposerStatusRow: View {
    let projectName: String?
    let mode: ComposerChatMode?
    /// M8.T03: the per-chat Memory off switch (nil = memory feature off: no toggle).
    var memoryOff: Binding<Bool>? = nil
    var memoryOffLocked = false

    var isEmpty: Bool { projectName == nil && mode == nil && memoryOff == nil }

    var body: some View {
        if !isEmpty {
            HStack(spacing: Spacing.space2) {
                if let projectName {
                    StatusChip(symbol: "folder", tint: .textSecondary, text: Text(verbatim: projectName))
                        .accessibilityIdentifier("statusProject")
                }
                if let mode {
                    StatusChip(symbol: mode == .evil ? "circle.fill" : "circle",
                               tint: mode == .evil ? .evilBase : .textTertiary,
                               text: Text(CopyKey(mode == .evil ? "mode.evil" : "mode.normal")))
                        .accessibilityIdentifier("statusMode")
                }
                Spacer(minLength: 0)
                if let memoryOff {
                    // VQ round 65 (S-05): a labelled chip ("Memory on" / "Memory off"), not a bare brain glyph that
                    // nothing explained.
                    Button { memoryOff.wrappedValue.toggle() } label: {
                        HStack(spacing: Spacing.space1) {
                            Image(systemName: memoryOff.wrappedValue ? "brain.slash" : "brain")  // SF Symbols 7
                                .font(.system(size: 11, weight: .medium))
                            Text(CopyKey(memoryOff.wrappedValue ? "composer.memory.off" : "composer.memory.on"))
                                .typeStyle(.footnote)
                                .lineLimit(1)
                        }
                        .foregroundStyle(memoryOff.wrappedValue ? Color.textPrimary : Color.textSecondary)
                        .padding(.horizontal, Spacing.space2)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Color.surfaceSunken))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(memoryOffLocked)
                    .help(Text(CopyKey(memoryOffLocked ? "composer.memoryOff.locked" : "composer.memoryOff")))
                    .accessibilityLabel(Text(CopyKey("composer.memoryOff")))
                    .accessibilityValue(Text(verbatim: memoryOff.wrappedValue ? "on" : "off"))
                    .accessibilityIdentifier("composer.memoryOff")
                }
            }
            .padding(.horizontal, Spacing.space3)
        }
    }
}

private struct StatusChip: View {
    let symbol: String
    let tint: Color
    let text: Text

    var body: some View {
        HStack(spacing: Spacing.space1) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "circle.fill" || symbol == "circle" ? 7 : 11, weight: .medium))
                .foregroundStyle(tint)
            text
                .typeStyle(.footnote)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Spacing.space2)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.surfaceSunken))
        .accessibilityElement(children: .combine)
    }
}
