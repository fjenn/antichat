// M7.T12 step 3 (R-082 AC1/AC3–AC5, R-261; S-21 §8; settings-map §8): Settings → Skills. One SkillRow per installed
// skill (name, description, source Built in / Added by you, on/off switch; states on / off / scripts need approval /
// invalid `skills.invalid`, plus `skills.needs`), each with Apply to every chat (off), Show in Finder (the folder is
// the editable copy), Export (zip via SkillExporter, validated) and Delete. [Add skill] takes a folder, .zip, .skill
// or SKILL.md and always opens SkillReviewSheet (full text) before anything is installed.
// UI tests: `-SkillImportFile <path>` stands in for the open panel, `-SkillExportDir <dir>` for the save panel.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class SkillsLibrary {
    static let shared = SkillsLibrary()

    private(set) var skills: [InstalledSkill] = []
    /// The candidate the review sheet shows (nil = closed).
    var reviewing: SkillImportCandidate?
    /// The last import / export / delete failure (shown under the list).
    var error: String?
    @ObservationIgnored var store: () -> SkillStore? = { SkillTools.store }
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// `observe: false` = a pinned library (snapshot tests) that other suites' `SkillTools.didChange` posts never reload.
    init(observe: Bool = true, store: (() -> SkillStore?)? = nil) {
        if let store { self.store = store }
        guard observe else { reload(); return }
        observer = NotificationCenter.default.addObserver(forName: SkillTools.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        guard let store = store() else { skills = []; return }
        try? store.reconcile()
        skills = store.list()
    }

    private func changed() {
        reload()
        NotificationCenter.default.post(name: SkillTools.didChange, object: nil)
    }

    // MARK: Switches

    func setEnabled(_ name: String, _ on: Bool) { perform { try $0.setEnabled(name, on) } }
    func setApplyAll(_ name: String, _ on: Bool) { perform { try $0.setApplyAll(name, on) } }
    func delete(_ name: String) { perform { try $0.delete(name) } }

    private func perform(_ body: (SkillStore) throws -> Void) {
        guard let store = store() else { return }
        do { try body(store); error = nil } catch { self.error = "\(error)" }
        changed()
    }

    // MARK: Add

    /// Stages `url` and opens the review sheet; a refused source (limits, zip-slip, symlink) shows `skills.invalid`.
    func beginImport(_ url: URL) {
        reviewing?.discard()
        do {
            reviewing = try SkillImporter.inspect(url)
            error = nil
        } catch {
            reviewing = nil
            self.error = CopyText(CopyKey("skills.invalid"), ["reason": Self.reason(error)]).string
        }
    }

    func install() {
        guard let c = reviewing, let store = store() else { return }
        do {
            try SkillImporter.install(c, into: store)
            error = nil
        } catch {
            self.error = CopyText(CopyKey("skills.invalid"), ["reason": Self.reason(error)]).string
        }
        reviewing = nil
        changed()
    }

    func cancelReview() {
        reviewing?.discard()
        reviewing = nil
    }

    func chooseAndImport() {
        if let i = CommandLine.arguments.firstIndex(of: "-SkillImportFile"), i + 1 < CommandLine.arguments.count {
            beginImport(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder, UTType(filenameExtension: "skill") ?? .zip,
                                     UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginImport(url)
    }

    // MARK: Export / reveal

    func export(_ name: String) {
        guard let store = store() else { return }
        let target: URL
        if let i = CommandLine.arguments.firstIndex(of: "-SkillExportDir"), i + 1 < CommandLine.arguments.count {
            target = URL(fileURLWithPath: CommandLine.arguments[i + 1]).appendingPathComponent("\(name).zip")
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(name).zip"
            panel.allowedContentTypes = [.zip]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
        }
        do { try SkillExporter.export(name, from: store, to: target); error = nil } catch { self.error = "\(error)" }
    }

    func reveal(_ name: String) {
        guard let store = store() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: name).appendingPathComponent("SKILL.md")])
    }

    // MARK: Needs

    /// `skills.needs` lines for a skill now ("needs Web search (off)").
    static func needs(_ s: InstalledSkill, webSearch: WebSearchAvailability.State = WebSearchAvailability().state) -> [CopyText] {
        var conns: [String: Bool] = [:]
        for t in MCPTools.shared.all { conns[t.serverName.lowercased()] = (conns[t.serverName.lowercased()] ?? false) || t.enabled }
        return SkillNeeds.evaluate(allowedTools: s.document?.allowedTools ?? [], webSearch: webSearch, connections: conns).map(needText)
    }

    static func needText(_ n: SkillNeed) -> CopyText {
        let feature: String = switch n.feature {
        case .webSearch: CopyKey("skills.needs.web").string()
        case .connection(let name): name
        }
        let state = CopyKey(n.state == .offline ? "skills.needs.offline" : "skills.needs.off").string()
        return CopyText(CopyKey("skills.needs"), ["feature": feature, "state": state])
    }

    static func reason(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// The library the Skills page shows (tests inject their own, isolated per test; the app uses `.shared`).
private struct SkillsLibraryKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: SkillsLibrary? = nil
}

extension EnvironmentValues {
    var skillsLibrary: SkillsLibrary? {
        get { self[SkillsLibraryKey.self] }
        set { self[SkillsLibraryKey.self] = newValue }
    }
}

struct SkillsPage: View {
    @Environment(\.skillsLibrary) private var injected
    private var library: SkillsLibrary { injected ?? .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(library.skills) { s in
                SkillRow(skill: s, library: library)
                Divider()
            }
            HStack {
                Button { library.chooseAndImport() } label: { Label { Text(CopyKey("skills.add")) } icon: { Image(systemName: "plus") } }
                    .probeID("skills.add")
                Spacer()
            }
            if let e = library.error {
                Text(verbatim: e).font(.caption).foregroundStyle(Color.danger).probeID("skills.error")
            }
        }
        .onAppear { library.reload() }
        .sheet(item: Bindable(library).reviewing) { c in
            SkillReviewSheet(candidate: c, onInstall: { library.install() }, onCancel: { library.cancelReview() })
        }
    }
}
