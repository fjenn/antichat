// Settings → About & Help (M1.T22 step 1; settings-map §13): Version, Help (the bundled guide placeholder until
// M10) and Report a problem (M8.T09 ReportProblemSheet), System report and Export diagnostics (M8.T09).
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct AboutSection: View {
    @Bindable var model: SettingsModel
    @State private var showingLegal = false

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        Section {
            // M10.T01 step 2: development builds (adhoc / Apple Development, never notarized) say so here.
            SettingsItem("version", description: BuildSignature.current.isDeveloperID ? nil : CopyKey("about.unnotarized")) {
                Text(verbatim: Self.version).foregroundStyle(Color.textSecondary).textSelection(.enabled)
            }
            SettingsItem("help") {
                Button { model.showingHelp = true } label: { Text(CopyKey("side.footer.help")) }
                    .probeID("settings.control.help")
            }
            SettingsItem("legal") {  // M10.T06 (R-217): the bundled, versioned pages
                Button { showingLegal = true } label: { Text(CopyKey("legal.title")) }
                    .probeID("settings.control.legal")
                    .sheet(isPresented: $showingLegal) { LegalSheet { showingLegal = false } }
            }
            SettingsItem("licences", description: CopyKey("set.about.licences.openDyslexic")) {
                // M1.T23: the bundled font's licence (the full Licences page arrives with M10).
                Text(verbatim: "OFL-1.1").foregroundStyle(Color.textSecondary).textSelection(.enabled)
            }
            SettingsItem("reportProblem") {
                Button { model.showingReport = true } label: { Text(CopyKey("set.about.report")) }
                    .probeID("settings.control.reportProblem")
            }
            SettingsItem("systemReport") {  // M8.T09 step 7
                Button { model.showingSystemReport = true } label: { Text(CopyKey("set.about.systemReport.button")) }
                    .probeID("settings.control.systemReport")
                    .sheet(isPresented: $model.showingSystemReport) {
                        SystemReportView(database: nil) { model.showingSystemReport = false }
                    }
            }
            SettingsItem("exportDiagnostics") {  // M8.T09 step 5
                Button { model.showingExportLogs = true } label: { Text(CopyKey("set.privacy.exportLogs.button")) }
                    .probeID("settings.control.exportDiagnostics")
            }
        }
    }
}
