// M8.T09 step 5 (R-218 AC3; S-24): Help › Export Logs… and Settings › Privacy & Data › Export logs. "Include chat
// content" is off by default; the bundle is redacted either way (LogBundleBuilder + Redaction).
import AntiChatDesign
import AntiChatPlatform
import AntiChatStorage
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportLogsSheet: View {
    let database: AppDatabase?
    let onClose: () -> Void
    @State private var includeContent = false
    @State private var result: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("logs.title")).typeStyle(.title3)
            Text(CopyKey("logs.body")).typeStyle(.callout).foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $includeContent) { Text(CopyKey("logs.includeContent")) }
                .toggleStyle(.checkbox)
                .probeID("logs.includeContent")
            if let result { Text(CopyText(CopyKey("logs.done"), ["filename": result])).typeStyle(.footnote).probeID("logs.done") }
            if failed { Text(CopyKey("logs.failed")).typeStyle(.footnote).foregroundStyle(Color.danger) }
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("logs.cancel")) }.keyboardShortcut(.cancelAction)
                Button { export() } label: { Text(CopyKey("logs.export")) }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .probeID("logs.export")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 460)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("exportLogsSheet")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LogBundleBuilder.fileName()
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let include = includeContent, db = database
        Task { @MainActor in
            do {
                try await DiagnosticsCenter.shared.buildLogBundle(to: url, includeContent: include, database: db)
                result = url.lastPathComponent
                failed = false
            } catch {
                failed = true
            }
        }
    }
}
