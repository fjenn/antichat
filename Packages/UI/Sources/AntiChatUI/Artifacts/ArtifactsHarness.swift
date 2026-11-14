// Debug host for the artifact components (M4.T10/T11; `-ArtifactsHarness <dir>`, Debug builds only through
// AntiChatApp): one FileCard per regular file in `<dir>` (sorted by name). FileCardTests drives it until M6.T13
// puts cards into assistant turns. Never shown in Release.
import AntiChatDesign
import AntiChatFoundation
import SwiftUI

public struct ArtifactsHarnessView: View {
    public static var launchDirectory: String? { LaunchOptions.current.artifactsHarness }

    @State private var cards: [FileCardViewModel]
    @State private var panel = SidePanelModel(windowID: "artifactsHarness")
    @State private var prefill = ""

    public init(directory: String) {
        let dir = URL(fileURLWithPath: directory)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey]))
            ?? []).filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        _cards = State(initialValue: files.map { FileCardViewModel(item: FileCardItem(url: $0, version: 1)) })
        // Version chains for SidePanelTests: `name.v2.ext` is version 2 of `name.ext`.
        var chains: [String: [PanelVersion]] = [:]
        for f in files {
            let parts = f.deletingPathExtension().lastPathComponent.components(separatedBy: ".v")
            let n = parts.count == 2 ? Int(parts[1]) ?? 1 : 1
            chains["\(parts[0]).\(f.pathExtension)", default: []].append(PanelVersion(n: n, url: f))
        }
        _chains = State(initialValue: chains)
        _autoOpen = State(initialValue: files.first { ["html", "svg"].contains($0.pathExtension.lowercased()) })
    }

    @State private var chains: [String: [PanelVersion]] = [:]
    @State private var autoOpen: URL?

    private func openInPanel(_ url: URL) {
        let parts = url.deletingPathExtension().lastPathComponent.components(separatedBy: ".v")
        let key = "\(parts[0]).\(url.pathExtension)"
        let n = parts.count == 2 ? Int(parts[1]) : 1
        panel.open(title: key, versions: chains[key] ?? [PanelVersion(n: 1, url: url)], selecting: n)
    }

    public var body: some View {
        SidePanelContainer(model: panel) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    ForEach(cards, id: \.item.id) { card in
                        FileCard(model: card, onOpenInPanel: { openInPanel(card.item.url) })
                    }
                    Text(verbatim: prefill).accessibilityIdentifier("harnessPrefill").typeStyle(.caption)
                }
                .padding(Spacing.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.surfaceCanvas)
        .accessibilityElement(children: .contain)  // keeps the cards' own identifiers (Q-015 catch-up)
        .accessibilityIdentifier("artifactsHarness")
        .onAppear {
            panel.onEditSelection = { prefill = $0 }
            // `make test-offline FILTER=SandboxedWebPreview`: the first HTML/SVG file opens in the panel at launch.
            if let autoOpen { openInPanel(autoOpen); self.autoOpen = nil }
        }
    }
}
