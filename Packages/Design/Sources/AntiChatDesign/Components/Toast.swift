// Toast (components.md §5: bottom-centre, ≤ 2 lines, optional action, auto-dismiss 5 s — not for errors that
// need action; info · success · warning).
import SwiftUI

public struct ToastAction: Sendable {
    public let title: CopyText
    public let perform: @MainActor @Sendable () -> Void

    public init(_ title: CopyText, perform: @escaping @MainActor @Sendable () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// One toast. A toast with an action stays until dismissed or acted on when `persistent` (errors that need
/// action); every other toast auto-dismisses after `Toast.autoDismiss`.
public struct Toast: Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case info, success, warning }

    public static let autoDismiss: Duration = .seconds(5)

    public let id = UUID()
    public let kind: Kind
    public let message: CopyText
    public let action: ToastAction?
    public let persistent: Bool

    public init(_ kind: Kind, _ message: CopyText, action: ToastAction? = nil, persistent: Bool = false) {
        self.kind = kind
        self.message = message
        self.action = action
        self.persistent = persistent
    }
}

extension Toast.Kind {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .info: .info
        case .success: .success
        case .warning: .warning
        }
    }
}

/// The toast card.
public struct ToastView: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let toast: Toast
    let onDismiss: () -> Void

    public init(_ toast: Toast, onDismiss: @escaping () -> Void = {}) {
        self.toast = toast
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            Image(systemName: toast.kind.symbol)
                .foregroundStyle(toast.kind.tint)
                .accessibilityHidden(true)
            Text(toast.message)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let action = toast.action {
                Button {
                    action.perform()
                    onDismiss()
                } label: {
                    Text(action.title).foregroundStyle(accentPreset.color)
                }
                .buttonStyle(.plain)
            }
        }
        .typeStyle(.callout)
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space3)
        .frame(maxWidth: 480)
        .background {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Color.surfaceRaised)
                .tokenShadow(.level2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

public extension View {
    /// Hosts a toast at the bottom centre; clears `toast` after 5 s unless it is persistent. `above`: the toast floats
    /// just above the host instead (M9.T08 R6: a control such as the composer, whose own controls the bottom-centre toast
    /// covered).
    func toast(_ toast: Binding<Toast?>, above: Bool = false) -> some View {
        modifier(ToastHost(toast: toast, above: above))
    }
}

private struct ToastHost: ViewModifier {
    @Binding var toast: Toast?
    var above = false
    @State private var lift: CGFloat = 0
    @EffectiveReduceMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: above ? .top : .bottom) {
            if let t = toast {
                ToastView(t) { toast = nil }
                    .padding(.bottom, above ? Spacing.space3 : Spacing.space6)
                    // `above`: lifted by its own height, so its bottom sits space3 over the host's top edge (an
                    // alignment guide inside the overlay was not honoured: the toast covered the composer's tiles).
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lift = $0 }
                    .offset(y: above ? -lift : 0)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: t.id) {
                        guard !t.persistent else { return }
                        try? await Task.sleep(for: Toast.autoDismiss)
                        if toast?.id == t.id { toast = nil }
                    }
                    .onAppear {
                        AccessibilityNotification.Announcement(t.message.string).post()
                    }
            }
        }
        .animation(MotionToken.base.animation(reduceMotion: reduceMotion) ?? MotionToken.base.reducedCrossFade,
                   value: toast?.id)
    }
}

#Preview("Toast") {
    VStack(spacing: Spacing.space4) {
        ToastView(Toast(.info, CopyText(CopyKey("model.usingLighter"))))
        ToastView(Toast(.success, CopyText(CopyKey("starter.upgraded"))))
        ToastView(Toast(.warning, CopyText(CopyKey("upload.unsupported"), ["ext": ".pages"]),
                        action: ToastAction(CopyText(CopyKey("msg.retry"))) {}))
    }
    .padding(Spacing.space7)
    .background(Color.surfaceCanvas)
}
