// Tooltip (components.md §5: label + shortcut, "Start voice ⌃⇧V").
import SwiftUI

/// The rendered tooltip bubble (custom hover cards, toolbar hints). For plain controls use `.tooltip(_:shortcut:)`,
/// which uses the native macOS help tag with the same text.
public struct Tooltip: View {
    let label: CopyText
    let shortcut: String?

    public init(_ label: CopyText, shortcut: String? = nil) {
        self.label = label
        self.shortcut = shortcut
    }

    /// "Label ⌃⇧V": the one string both the bubble and the native help tag show.
    public static func text(_ label: CopyText, shortcut: String?) -> String {
        [label.string, shortcut].compactMap { $0 }.joined(separator: " ")
    }

    public var body: some View {
        HStack(spacing: Spacing.space2) {
            Text(label)
                .foregroundStyle(Color.textPrimary)
            if let shortcut {
                Text(verbatim: shortcut)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .typeStyle(.footnote)
        .padding(.horizontal, Spacing.space2)
        .padding(.vertical, Spacing.space1)
        .background {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(Color.surfaceRaised)
                .tokenShadow(.level1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: Self.text(label, shortcut: shortcut)))
    }
}

public extension View {
    /// Native help tag with a copy key and an optional shortcut glyph string.
    func tooltip(_ label: CopyText, shortcut: String? = nil) -> some View {
        help(Tooltip.text(label, shortcut: shortcut))
    }
}

#Preview("Tooltip") {
    VStack(spacing: Spacing.space4) {
        Tooltip(CopyText(CopyKey("tip.think")))
        Tooltip(CopyText(CopyKey("side.newChat")), shortcut: "⌘N")
    }
    .padding(Spacing.space7)
    .background(Color.surfaceCanvas)
}
