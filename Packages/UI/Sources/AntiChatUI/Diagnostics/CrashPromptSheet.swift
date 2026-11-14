// M8.T09 step 3 (R-218 AC2, NFR-PR2; S-24): the next-launch crash prompt. Title + body (copy deck), [Preview] (the
// exact payload, monospaced, scrollable, Copy), [Send], [Don't send], [Always send]. Nothing is sent without a tap;
// Send hands the payload to Mail or GitHub (DiagnosticsCenter). Shown only after onboarding is complete.
import AntiChatDesign
import AntiChatPlatform
import AppKit
import SwiftUI

struct CrashPromptSheet: View {
    let reports: [CrashReport]
    let controller: CrashPromptController
    let onClose: () -> Void
    @State private var previewing = false

    var payload: String { CrashPromptController.payload(reports) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("crash.prompt.title")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            Text(CopyKey("crash.prompt.body")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if previewing { CrashPreviewView(text: payload) }
            HStack {
                Button { previewing.toggle() } label: { Text(CopyKey("crash.prompt.preview")) }
                    .probeID("crash.preview")
                Spacer()
                Button { controller.dontSend(); onClose() } label: { Text(CopyKey("crash.prompt.dontSend")) }
                    .keyboardShortcut(.cancelAction)
                    .probeID("crash.dontSend")
                // No real hand-off endpoint (release build before M10): Send / Always would go nowhere.
                Button { controller.alwaysSend(reports); onClose() } label: { Text(CopyKey("crash.prompt.always")) }
                    .disabled(controller.endpoints == nil)
                    .probeID("crash.always")
                Button { controller.send(reports); onClose() } label: { Text(CopyKey("crash.prompt.send")) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(payload.isEmpty || controller.endpoints == nil)
                    .probeID("crash.send")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 520)
        .background(Color.surfaceCanvas)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("crashPrompt")
    }
}

/// The exact payload text (monospaced, scrollable, selectable) with Copy.
struct CrashPreviewView: View {
    let text: String

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.space2) {
            ScrollView {
                Text(verbatim: text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.space2)
            }
            .frame(height: 220)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .probeID("crash.previewText")
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Text(CopyKey("crash.preview.copy")) }
                .accessibilityIdentifier("crash.preview.copy")
        }
    }
}
