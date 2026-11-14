// ErrorInline (components.md §3: icon + one sentence + action buttons from `AntiChatError.recovery`, per error
// code, copy-deck §8; IS-10). The recovery → button mapping arrives with RecoveryAction (M1.T05); until then the
// caller passes the actions.
import AntiChatFoundation
import SwiftUI

public struct ErrorInline: View {
    public struct Action: Identifiable {
        public enum Role: Sendable { case primary, secondary }
        public let id = UUID()
        public let title: CopyText
        public let role: Role
        public let perform: () -> Void

        public init(_ title: CopyText, role: Role = .secondary, perform: @escaping () -> Void) {
            self.title = title
            self.role = role
            self.perform = perform
        }
    }

    let message: CopyText
    let actions: [Action]

    public init(_ message: CopyText, actions: [Action] = []) {
        self.message = message
        self.actions = actions
    }

    /// The error's `userMessageKey` (never raw third-party text: the boundary rule of architecture §7.1).
    public init(_ error: AntiChatError, args: [String: String] = [:], actions: [Action] = []) {
        self.init(CopyText(CopyKey(error.userMessageKey), args), actions: actions)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(Color.danger)
                    .accessibilityHidden(true)
                Text(message)
                    .foregroundStyle(Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .typeStyle(.body)
            if !actions.isEmpty {
                HStack(spacing: Spacing.space2) {
                    ForEach(actions) { a in
                        if a.role == .primary {
                            Button(action: a.perform) { Text(a.title) }.buttonStyle(PrimaryButtonStyle())
                        } else {
                            Button(action: a.perform) { Text(a.title) }.buttonStyle(.bordered)
                        }
                    }
                }
                .controlSize(.regular)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

#Preview("ErrorInline") {
    VStack(alignment: .leading, spacing: Spacing.space6) {
        ErrorInline(CopyText(CopyKey("engine.restarted")), actions: [.init(CopyText(CopyKey("msg.retry"))) {}])
        ErrorInline(CopyText(CopyKey("engine.versionMismatch")),
                    actions: [.init(CopyText(CopyKey("engine.restartApp")), role: .primary) {}])
    }
    .padding(Spacing.space7)
    .frame(width: 560, alignment: .leading)
    .background(Color.surfaceCanvas)
}
