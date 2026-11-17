// Debug-only composer host for App/UITests/ComposerTests (AT-002) until the lead wires the composer into
// MainWindow at the W2 merge (M1-plan W2: T07 owns MainWindow, T06's TurnController.send binds `onSend`).
// Launched with `-ComposerHarness <fixture>` (M1.md convention 10). A send "generates" for 1.5 s (or until Stop),
// standing in for the T06 turn; probes expose what was sent so the tests can check the payload.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatDesign
import AntiChatFoundation
import SwiftUI

public struct ComposerHarnessView: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    /// The `-ComposerHarness` fixture of this launch, or nil (the app then shows its normal window).
    public static var launchFixture: String? { LaunchOptions.current.composerHarness }

    @State private var model: ComposerModel
    @State private var sent: [ComposerSubmission] = []
    @State private var reply: Task<Void, Never>?

    public init(fixture: String, options: LaunchOptions = .current) {
        let m = ComposerModel(evilEnabled: options.fakeEvilEnabled)
        switch fixture {
        case "project+mode":
            m.statusProjectName = "Fixture project"
            m.statusMode = .evil
            m.mode = .evil
        case "noModel":
            m.availability = .noModel
        case "queued":
            m.availability = .queued(percent: 42)
        case "incognito":
            m.isIncognito = true
        default:
            break
        }
        _model = State(initialValue: m)
    }

    public var body: some View {
        VStack(spacing: 0) {
            probes
            Spacer(minLength: 0)
            ComposerView(model: model, maxTextHeight: nil)
                .frame(maxWidth: readingWidth)
                .padding(.horizontal, Spacing.space4)
                .padding(.bottom, Spacing.space4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceCanvas)
        .onAppear(perform: bind)
    }

    private var probes: some View {
        HStack(spacing: Spacing.space3) {
            // ux/simplify: the mode picker lives in the window toolbar; the harness has none, so it sits up here.
            if model.evilEnabled { ModePicker(mode: Bindable(model).mode, isLocked: model.modeLocked) }
            probe("harnessSendCount", "\(sent.count)")
            probe("harnessLastSent", sent.last?.markdown ?? "")
            probe("harnessLastAttachments", "\(sent.last?.attachments.count ?? 0)")
            probe("harnessBoldRuns", "\(model.debugBoldRunCount)")
            probe("harnessLineCount", "\(model.lineCount)")
            Spacer()
        }
        .typeStyle(.caption)
        .foregroundStyle(Color.textTertiary)
        .padding(Spacing.space2)
    }

    private func probe(_ id: String, _ value: String) -> some View {
        Text(verbatim: "\(id)=\(value.prefix(40))")
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(id)=\(value.prefix(40))"))  // "id=value" as the label (Q-015 r2: a bare
            .accessibilityIdentifier(id)  // .accessibilityElement() dropped the text, so XCUITest read "")
    }

    private func bind() {
        model.onSend = { submission in
            sent.append(submission)
            reply?.cancel()
            reply = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled else { return }
                model.turnFinished()
            }
        }
        model.onStop = {
            reply?.cancel()
            reply = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                model.turnFinished()
            }
        }
    }
}
#endif
