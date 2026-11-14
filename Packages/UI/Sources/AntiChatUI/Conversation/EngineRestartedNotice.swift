// Engine states of S-25 (screens.md "Engine restarted: InterruptedNotice + engine.restarted"; "OOM fallback:
// model.usingLighter / model.notEnoughMemory + Retry"; components.md §3 InterruptedNotice, ErrorInline, Banner).
// M1.T12. EngineRestartedNotice wraps M1.T06's `InterruptedNotice` (`interruptedNotice`, `msg.interrupted`,
// [Edit prompt] [Retry]); ConversationView's assistant row (AssistantMessageView) hosts it for a turn that ended
// with `engine.restarted` (inserted at the W2 + T12 integration merge).
import AntiChatDesign
import AntiChatFoundation
import SwiftUI

/// A turn cut off by a helper crash: partial reply above, then "Response interrupted." + "The AI engine
/// restarted." with [Retry] (and [Edit prompt] when the caller offers it). It is M1.T06's `InterruptedNotice`
/// with the `engine.restarted` reason (M1.md AT-004: "the crash script produces the identical notice plus
/// `engine.restarted`"), so J02/J13 query the same identifiers (`interruptedNotice`, `interruptedReason`,
/// `interruptedRetry`); the outer `engineRestartedNotice` marks the S-25 engine-crash state.
public struct EngineRestartedNotice: View {
    let onRetry: () -> Void
    let onEdit: (() -> Void)?

    public init(onRetry: @escaping () -> Void, onEdit: (() -> Void)? = nil) {
        self.onRetry = onRetry
        self.onEdit = onEdit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InterruptedNotice(errorCode: AntiChatError.Code.engineRestarted.rawValue, onEdit: onEdit, onRetry: onRetry)
        }
        .accessibilityElement(children: .contain)
        .probeID("engineRestartedNotice")
    }
}

/// `model.usingLighter`: one muted line under the reply (no action).
public struct UsingLighterModelNotice: View {
    public init() {}

    public var body: some View {
        Text(CopyText(CopyKey("model.usingLighter")))
            .typeStyle(.footnote)
            .foregroundStyle(Color.textSecondary)
            .accessibilityIdentifier("model.usingLighter")
    }
}

/// `model.notEnoughMemory` + [Retry] in place of the reply (the user message stays above it).
public struct NotEnoughMemoryNotice: View {
    let onRetry: () -> Void

    public init(onRetry: @escaping () -> Void) { self.onRetry = onRetry }

    public var body: some View {
        ErrorInline(AntiChatError(.modelNotEnoughMemory), actions: [.init(CopyText(CopyKey("msg.retry")), perform: onRetry)])
            .accessibilityIdentifier("model.notEnoughMemory")
    }
}

/// A media job swept to `lost` by LaunchRecovery (R-208 AC4). M1 has no job card yet (M4), so the fixture row
/// renders as ErrorInline "Response interrupted." + [Retry]; M4's card uses `img.lost`.
public struct LostMediaJobNotice: View {
    let onRetry: () -> Void

    public init(onRetry: @escaping () -> Void) { self.onRetry = onRetry }

    public var body: some View {
        ErrorInline(CopyText(CopyKey("msg.interrupted")), actions: [.init(CopyText(CopyKey("msg.retry")), perform: onRetry)])
            .accessibilityIdentifier("mediaJob.lost")
    }
}

/// `engine.crashLoop`: non-dismissible banner at the top of the chat column, [Restart AntiChat].
public struct EngineCrashLoopBanner: View {
    let onRestart: () -> Void

    public init(onRestart: @escaping () -> Void) { self.onRestart = onRestart }

    public var body: some View {
        Banner(.danger, CopyText(CopyKey("engine.crashLoop")),
               action: .init(CopyText(CopyKey("engine.restartApp")), perform: onRestart), onDismiss: nil)
            .accessibilityIdentifier("engine.crashLoop")
    }
}

#Preview("Engine notices") {
    VStack(alignment: .leading, spacing: Spacing.space6) {
        EngineRestartedNotice(onRetry: {}, onEdit: {})
        UsingLighterModelNotice()
        NotEnoughMemoryNotice(onRetry: {})
        EngineCrashLoopBanner(onRestart: {})
    }
    .padding(Spacing.space7)
    .frame(width: 560, alignment: .leading)
    .background(Color.surfaceCanvas)
}
