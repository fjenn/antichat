// InterruptedNotice (components.md §3; IS-5, R-004, NFR-S2): a bordered notice `msg.interrupted` with
// [Edit prompt] (`msg.interrupted.edit`) and [Retry] (`msg.retry`). The same notice after Stop, after crash
// recovery (launch sweep) and after an engine failure; for the latter the error's line (e.g. `engine.restarted`)
// is shown inside it (R-004 AC3).
import AntiChatDesign
import AntiChatFoundation
import SwiftUI

public struct InterruptedNotice: View {
    let reasonKey: String?
    let onEdit: (() -> Void)?
    let onRetry: () -> Void

    /// - Parameter errorCode: the `AntiChatError.fullCode` that ended the reply, if any (its copy key is shown).
    /// - Parameter onEdit: nil hides [Edit prompt].
    public init(errorCode: String? = nil, onEdit: (() -> Void)?, onRetry: @escaping () -> Void) {
        reasonKey = errorCode.map { AntiChatError.Code(rawValue: $0)?.userMessageKey ?? "engine.error" }
        self.onEdit = onEdit
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyText(CopyKey("msg.interrupted")))
                .typeStyle(.callout)
                .foregroundStyle(Color.textPrimary)
                .accessibilityIdentifier("interruptedMessage")
            if let reasonKey {
                Text(CopyText(CopyKey(reasonKey)))
                    .typeStyle(.subhead)
                    .foregroundStyle(Color.textSecondary)
                    .probeID("interruptedReason")
            }
            HStack(spacing: Spacing.space2) {
                if let onEdit {
                    Button(action: onEdit) { Text(CopyText(CopyKey("msg.interrupted.edit"))) }
                        .probeID("interruptedEdit")
                }
                Button(action: onRetry) { Text(CopyText(CopyKey("msg.retry"))) }
                    .probeID("interruptedRetry")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.borderControl, lineWidth: Stroke.control))
        .accessibilityElement(children: .contain)
        .probeID("interruptedNotice")
    }
}

#Preview("InterruptedNotice") {
    VStack(spacing: Spacing.space6) {
        InterruptedNotice(onEdit: {}, onRetry: {})
        InterruptedNotice(errorCode: "engine.restarted", onEdit: {}, onRetry: {})
    }
    .padding(Spacing.space7)
    .frame(width: 560)
    .background(Color.surfaceCanvas)
}
