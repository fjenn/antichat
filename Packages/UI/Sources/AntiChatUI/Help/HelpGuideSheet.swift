// M10.T07 step 1 (R-303 AC1): Help › AntiChat Help. Online (a network path and Offline only off) → the help centre
// in the browser; otherwise this sheet with the bundled short guide (Resources/Help/guide.md) and the offline note.
import AntiChatDesign
import AntiChatNetwork
import AntiChatPlatform
import AppKit
import Network
import SwiftUI

enum HelpCentre {
    /// The site's help centre (from the hosting switch: DownloadURL's site root; SiteLinks).
    static var url: URL? { SiteLinks.url("/help/faq/") }

    /// Pure decision (unit-tested): open the browser only with a usable path and Offline only off.
    static func opensBrowser(pathSatisfied: Bool, offlineOnly: Bool) -> Bool { pathSatisfied && !offlineOnly }

    /// Help › AntiChat Help: the browser when online, else `showGuide()`.
    @MainActor static func open(showGuide: @escaping @MainActor () -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            monitor.cancel()
            let online = opensBrowser(pathSatisfied: path.status == .satisfied, offlineOnly: NetworkPolicyStore.shared.offlineOnly)
            Task { @MainActor in
                if online, let u = url { SiteLinks.open(u) } else { showGuide() }
            }
        }
        monitor.start(queue: .main)
    }
}

struct HelpGuideSheet: View {
    var offline = true
    let onClose: () -> Void
    private let guide = BundledDocument.load("guide", subdirectory: nil)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            if offline {
                Text(CopyKey("help.offline")).typeStyle(.callout).foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("help.offlineNote")
            }
            ScrollView {
                Text(guide?.attributed ?? AttributedString("")).typeStyle(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.space3)
                    .accessibilityIdentifier("help.guide.body")
            }
            .frame(height: 420)
            HStack {
                Button { if let u = HelpCentre.url { SiteLinks.open(u) } } label: { Text(CopyKey("help.openCentre")) }
                    .accessibilityIdentifier("help.openCentre")
                Spacer()
                Button(action: onClose) { Text(CopyKey("help.placeholder.close")) }
                    .keyboardShortcut(.defaultAction).probeID("help.close")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 600)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("help.guide")
    }
}
