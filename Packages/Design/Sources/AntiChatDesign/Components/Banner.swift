// Banner (components.md §5: top of the chat column, dismissible; notifications off · update ready ·
// catalog expired (warn only) · model removed by revocation).
import SwiftUI

public struct Banner: View {
    public enum Kind: String, CaseIterable, Sendable { case info, warning, danger }

    public struct Action {
        public let title: CopyText
        public let perform: () -> Void
        public init(_ title: CopyText, perform: @escaping () -> Void) {
            self.title = title
            self.perform = perform
        }
    }

    let kind: Kind
    let message: CopyText
    let action: Action?
    let onDismiss: (() -> Void)?

    /// - Parameter onDismiss: `nil` hides the × (a banner that must stay, e.g. `engine.crashLoop`).
    public init(_ kind: Kind, _ message: CopyText, action: Action? = nil, onDismiss: (() -> Void)? = nil) {
        self.kind = kind
        self.message = message
        self.action = action
        self.onDismiss = onDismiss
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .danger: "exclamationmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: .info
        case .warning: .warning
        case .danger: .danger
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.perform) { Text(action.title) }
                    .controlSize(.small)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: Layout.hitTargetMin.width, height: Layout.hitTargetMin.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(CopyKey("a11y.dismiss")))
                .tooltip(CopyText(CopyKey("a11y.dismiss")))
            }
        }
        .typeStyle(.callout)
        .padding(.leading, Spacing.space4)
        .padding(.trailing, onDismiss == nil ? Spacing.space4 : Spacing.space1)
        .padding(.vertical, Spacing.space2)
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Banner") {
    VStack(spacing: Spacing.space4) {
        Banner(.warning, CopyText(CopyKey("permission.notifications.off")), onDismiss: {})
        Banner(.info, CopyText(CopyKey("catalog.expired")),
               action: Banner.Action(CopyText(CopyKey("set.updates.check"))) {}, onDismiss: {})
        Banner(.danger, CopyText(CopyKey("engine.crashLoop")),
               action: Banner.Action(CopyText(CopyKey("engine.restartApp"))) {})
    }
    .frame(width: 640)
    .padding(Spacing.space7)
    .background(Color.surfaceCanvas)
}
