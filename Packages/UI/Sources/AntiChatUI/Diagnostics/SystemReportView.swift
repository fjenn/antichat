// M8.T09 step 7 (R-218 AC5; S-21 About & Help): the system report (tier, speed class, budget, loaded models, load
// times, TTFT / tok/s p50, catalog, versions, FileVault) as text with [Copy]. No chat content.
import AntiChatDesign
import AntiChatPlatform
import AntiChatStorage
import AppKit
import SwiftUI

struct SystemReportView: View {
    let database: AppDatabase?
    let onClose: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("systemReport.title")).typeStyle(.title3)
            ScrollView {
                Text(verbatim: text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.space3)
            }
            .frame(height: 240)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .probeID("systemReport.text")
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Text(CopyKey("systemReport.copy")) }
                    .probeID("systemReport.copy")
                Button(action: onClose) { Text(CopyKey("systemReport.close")) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 520)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("systemReport")
        .task {
            let db = database
            let center = DiagnosticsCenter.shared
            text = await center.liveSystemReport(database: db).text()
        }
    }
}
