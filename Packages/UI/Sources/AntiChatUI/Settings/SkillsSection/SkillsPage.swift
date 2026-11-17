// M7.T12 step 3 (R-082 AC1/AC3–AC5, R-261; S-21 §8; settings-map §8): Settings → Skills, laid out like the
// Connections page (owner 2026-11-16). The header stays put: title, search, [Add] and one line saying what a skill
// is. Under it "Installed" and two columns of SkillRows (icon, name, description, a check mark while the skill is on;
// states on / off / scripts need approval / invalid `skills.invalid`, plus `skills.needs`), each with Turn on / off,
// Apply to every chat, Show in Finder (the folder is the editable copy), Export (zip via SkillExporter, validated) and
// Delete in its ⋯ / context menu. A long list folds behind "See X, Y and N more". [Add] takes a folder, .zip, .skill
// or SKILL.md and always opens SkillReviewSheet (full text) before anything is installed. Below "Installed": the
// catalogue of skills to install (`SkillsCatalog`), by category with six each — a category with more says how many
// and "See all" — and, last, "Browse all N skills"; both open the whole list, A to Z, with one chip per category.
// `+` downloads and verifies that skill (the page's only network use) and opens the same review sheet. The search
// field looks through both. A quiet last line opens the catalogue's sources and licences.
// Updates (SkillProvenance.swift): an installed skill that came from the catalogue, is still as it was installed and
// has other files in the index now gets a quiet "Update" in its row; with two or more, the Installed title row also
// says how many and offers "Update all". Pressing it downloads and verifies the new files (the network is only ever
// used on that press; never in Offline only, where the button is disabled) and swaps them in — after the same review
// sheet when the update adds or changes a script or asks for other tools, directly otherwise. On / off stays as it
// was; a failure is one plain line in the row and the installed copy is untouched.
// The catalogue is `SkillsCatalog.shared`: opening the page asks for a newer index when the last check is a day old
// (`DirectoryCatalogs.refresh(userOpened:)`), and the page reads it again when one arrives (`didChange`).
// UI tests: `-SkillImportFile <path>` stands in for the open panel, `-SkillExportDir <dir>` for the save panel.
import AntiChatDesign
import AntiChatHarness
import AntiChatNetwork
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
    /// The catalogue skills being downloaded (their ids), and why the last try of one failed.
    private(set) var installing: Set<String> = []
    private(set) var catalogErrors: [String: String] = [:]
    /// The catalogue entry the candidate under review was downloaded from (nil = the user's own file).
    private(set) var reviewingSource: SkillsCatalog.Skill?
    /// The candidate under review is an update of an installed skill, and this is what it changes (nil = an Add).
    private(set) var reviewingChange: SkillUpdateChange?
    /// The installed skills (by name) the catalogue has a newer version of; the ones being updated now, and why the
    /// last try of one failed.
    private(set) var updates: [String: SkillsCatalog.Skill] = [:]
    private(set) var updating: Set<String> = []
    private(set) var updateErrors: [String: String] = [:]
    /// Offline only is on: nothing is downloaded, Update is disabled.
    private(set) var offline = false
    @ObservationIgnored var store: () -> SkillStore? = { SkillTools.store }
    /// Fetches a catalogue skill into a temp folder (the only network use of the page; tests stub it).
    @ObservationIgnored var download: (SkillsCatalog.Skill) async throws -> URL = { try await SkillsCatalogInstaller.download($0) }
    /// The index the installed skills are compared with (no request: `SkillsCatalog.shared` is what is on disk).
    @ObservationIgnored var catalog: () -> SkillsCatalog = { .shared }
    @ObservationIgnored var offlineOnly: () -> Bool = { NetworkPolicyStore.shared.offlineOnly }
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
        offline = offlineOnly()
        guard let store = store() else { skills = []; updates = [:]; return }
        try? store.reconcile()
        let catalog = catalog()
        // Once per store: skills installed from the catalogue before their source was recorded.
        store.adoptCatalogSkills(from: [catalog, .bundled])
        skills = store.list()
        updates = store.availableUpdates(in: catalog)
        updateErrors = updateErrors.filter { updates[$0.key] != nil }
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
        reviewingSource = nil
        reviewingChange = nil
        do {
            reviewing = try SkillImporter.inspect(url)
            error = nil
        } catch {
            reviewing = nil
            self.error = CopyText(CopyKey("skills.invalid"), ["reason": Self.reason(error)]).string
        }
    }

    /// `+` on a catalogue skill: downloads and verifies its files, then opens the same review sheet as any other Add.
    /// A failure is one plain line under that skill.
    func installFromCatalog(_ skill: SkillsCatalog.Skill) async {
        guard installing.insert(skill.id).inserted else { return }
        catalogErrors[skill.id] = nil
        defer { installing.remove(skill.id) }
        do {
            let folder = try await download(skill)
            defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
            beginImport(folder)
            if reviewing != nil { reviewingSource = skill } else { catalogErrors[skill.id] = error; error = nil }
        } catch {
            let network = (error as? SkillsCatalogInstaller.Failure)?.isNetwork ?? true
            catalogErrors[skill.id] = CopyKey(network ? "skills.catalog.failed" : "skills.catalog.unverified").string()
        }
    }

    func install() {
        guard let c = reviewing, let store = store() else { return }
        let source = reviewingSource, update = reviewingChange != nil
        reviewing = nil
        reviewingChange = nil
        do {
            if update, let source { try SkillImporter.update(c, into: store, source: source) }
            else { try SkillImporter.install(c, into: store, source: source) }
            error = nil
            changed()
        } catch {
            changed()
            if update { updateErrors[c.name] = CopyKey("skills.update.failed").string() }
            else { self.error = CopyText(CopyKey("skills.invalid"), ["reason": Self.reason(error)]).string }
        }
    }

    func cancelReview() {
        reviewing?.discard()
        reviewing = nil
        reviewingChange = nil
    }

    // MARK: Update

    /// "Update" on an installed skill: downloads and verifies the catalogue's newer files, then replaces the
    /// installed copy — directly when only text changed, after the review sheet when scripts or `allowed-tools` did.
    /// On / off stays as it was. A failure is one plain line in that row; the installed copy is as before.
    func update(_ name: String) async {
        offline = offlineOnly()
        guard !offline, let entry = updates[name], let store = store(), updating.insert(name).inserted else { return }
        updateErrors[name] = nil
        defer { updating.remove(name) }
        do {
            let folder = try await download(entry)
            defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
            let candidate = try SkillImporter.inspect(folder)
            guard candidate.canInstall, candidate.name == name, let installed = store.skill(named: name) else {
                candidate.discard()
                throw SkillsCatalogInstaller.Failure.entry(name)
            }
            if let change = SkillUpdateChange.between(installed: installed, in: store.directory(for: installed.record.path), candidate: candidate) {
                reviewing?.discard()
                reviewing = candidate
                reviewingSource = entry
                reviewingChange = change
                return
            }
            try SkillImporter.update(candidate, into: store, source: entry)
            changed()
        } catch {
            let network = (error as? SkillsCatalogInstaller.Failure)?.isNetwork ?? !(error is SkillsCatalogInstaller.Failure)
            updateErrors[name] = CopyKey(network ? "skills.update.failed" : "skills.update.unverified").string()
        }
    }

    /// "Update all": one after the other; stops at the first that has to be reviewed (its sheet is open then, the
    /// rest keep their own Update).
    func updateAll() async {
        for name in updates.keys.sorted() {
            await update(name)
            if reviewing != nil { return }
        }
    }

    func chooseAndImport() {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // Probes and UI tests: `-SkillImportFile <path>` stands in for the open panel.
        if let i = CommandLine.arguments.firstIndex(of: "-SkillImportFile"), i + 1 < CommandLine.arguments.count {
            beginImport(URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        #endif
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
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // Probes and UI tests: `-SkillExportDir <dir>` stands in for the save panel.
        let exportDir: String? = CommandLine.arguments.firstIndex(of: "-SkillExportDir")
            .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        #else
        let exportDir: String? = nil
        #endif
        if let exportDir {
            target = URL(fileURLWithPath: exportDir).appendingPathComponent("\(name).zip")
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
    /// More installed skills than this (by at least three) fold behind "See X, Y and N more".
    static let folded = 8
    /// The skills a catalogue category shows on the overview (three per column).
    static let preview = 6

    @Environment(\.skillsLibrary) private var injected
    @State private var query: String
    /// The whole catalogue is showing (false = the overview), narrowed to `category` (nil = every skill, A to Z).
    @State private var browsing: Bool
    @State private var category: String?
    @State private var expanded = false
    @State private var showingNotice = false
    @State private var catalog: SkillsCatalog
    /// The page shows `SkillsCatalog.shared` and re-reads it when a newer index arrives (false = a fixed catalogue
    /// was passed in).
    private let followsLive: Bool
    private var library: SkillsLibrary { injected ?? .shared }

    /// `catalog`, `query`, `category`, `browseAll`: a fixed page to draw (snapshots).
    init(catalog: SkillsCatalog? = nil, query: String = "", category: String? = nil, browseAll: Bool = false) {
        _query = State(initialValue: query)
        _category = State(initialValue: category)
        _browsing = State(initialValue: browseAll || category != nil)
        _catalog = State(initialValue: catalog ?? .shared)
        followsLive = catalog == nil
    }

    /// Whether a `DirectoryCatalogs.didChange` post means this page should read `SkillsCatalog.shared` again.
    static func shouldReload(_ note: Notification, followsLive: Bool) -> Bool {
        followsLive && note.userInfo?["kind"] as? String == DirectoryCatalogs.Kind.skills.rawValue
    }

    private var search: String { query.trimmingCharacters(in: .whitespaces) }
    /// The categories that hold a skill (an empty "Other" never shows).
    private var categories: [SkillsCatalog.Category] { catalog.categories.filter { !catalog.skills(in: $0.id).isEmpty } }
    private var skillCount: [String: String] { ["count": catalog.skills.count.formatted()] }

    /// The installed skills the search leaves: name or description contains it (case and accents ignored).
    private var installed: [InstalledSkill] {
        guard !search.isEmpty else { return library.skills }
        return library.skills.filter {
            "\(SkillDisplay.name($0)) \($0.name) \(SkillDisplay.summary($0))".range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DirectoryHeader(section: .skills, query: $query,
                            search: (CopyText(CopyKey("skills.search"), skillCount), "skills.search")) {
                Button { library.chooseAndImport() } label: {
                    Label { Text(CopyKey("set.add")) } icon: { Image(systemName: "plus") }
                }
                .buttonStyle(.primary)
                .help(CopyKey("skills.add").string())
                .accessibilityLabel(Text(CopyKey("skills.add")))
                .id("addSkill")
                .probeID("skills.add")
            }
            .directoryHeaderPadding()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space6) {
                    if browsing, search.isEmpty {
                        VStack(alignment: .leading, spacing: Spacing.space4) {
                            DirectoryBackTitle(title: CopyKey("skills.all.title").string(), id: "skills.back") { browsing = false; category = nil }
                            DirectoryChips(categories: categories.map { ($0.id, $0.title) }, selection: $category, id: "skills.chip")
                            grid(category.map { catalog.skills(in: $0) }
                                ?? catalog.skills.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending })
                        }
                    } else {
                        overview
                    }
                }
                .directoryContentPadding()
            }
            .id(search.isEmpty ? (browsing ? "all.\(category ?? "")" : "") : "search")  // a new list starts at its top
        }
        .onAppear { library.reload() }
        // The list of skills: asked for when the page opens with a copy a day old; never in Offline only.
        .task { if followsLive { await DirectoryCatalogs.live?.refresh(userOpened: true) } }
        .onReceive(NotificationCenter.default.publisher(for: DirectoryCatalogs.didChange)) { note in
            if Self.shouldReload(note, followsLive: followsLive) {
                catalog = .shared
                // A category the newer index no longer has would leave an empty list behind its chip.
                if let c = category, catalog.skills(in: c).isEmpty { category = nil }
                library.reload()  // a newer index may hold updates for installed skills
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkPolicyStore.didChange)) { _ in library.reload() }
        .sheet(item: Bindable(library).reviewing) { c in
            SkillReviewSheet(candidate: c, source: library.reviewingSource, update: library.reviewingChange,
                             onInstall: { library.install() }, onCancel: { library.cancelReview() })
        }
        .sheet(isPresented: $showingNotice) { SkillsNoticeSheet { showingNotice = false } }
    }

    /// "Installed", then the catalogue by category; while searching, the matches of both.
    @ViewBuilder private var overview: some View {
        let mine = installed
        let found = search.isEmpty ? [] : catalog.search(search).filter { s in !mine.contains { $0.name == s.name } }
        let fold = search.isEmpty && !expanded && mine.count >= Self.folded + 3
        if mine.isEmpty, found.isEmpty, !search.isEmpty {
            Text(CopyText(CopyKey("skills.search.none"), ["query": search]))
                .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                .directoryInset()
                .probeID("skills.search.none")
        }
        if !mine.isEmpty || search.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
                    DirectorySectionTitle(title: Text(CopyKey("skills.installed")))
                    Spacer(minLength: Spacing.space3)
                    // Only with several: one update has its own button right there in its row.
                    if library.updates.count > 1 {
                        Text(verbatim: CopyText(CopyKey("skills.updates.available"), ["count": "\(library.updates.count)"]).string + " ·")
                            .typeStyle(.subhead).foregroundStyle(Color.textSecondary).lineLimit(1)
                            .probeID("skills.updates.available")
                        DirectoryTextButton(title: CopyKey("skills.updateAll"), label: CopyKey("skills.updateAll").string(),
                                            help: library.offline ? CopyKey("network.blockedByOfflineOnly").string() : nil,
                                            id: "skills.updateAll", padded: false) {
                            Task { await library.updateAll() }
                        }
                        .disabled(library.offline || !library.updating.isEmpty)
                    }
                }
                .directoryInset()
                Divider().directoryInset()
                DirectoryGrid {
                    ForEach(fold ? Array(mine.prefix(Self.folded)) : mine) { s in SkillRow(skill: s, library: library) }
                }
                if fold {
                    let rest = mine.dropFirst(Self.folded).map(SkillDisplay.name)
                    Button { expanded = true } label: {
                        Text(CopyText(CopyKey("skills.more"), ["first": rest[0], "second": rest[1], "count": "\(rest.count - 2)"]))
                            .typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .directoryInset()
                    .probeID("skills.more")
                }
                if let e = library.error {
                    Text(verbatim: e).typeStyle(.footnote).foregroundStyle(Color.danger).directoryInset().probeID("skills.error")
                }
            }
        }
        if !found.isEmpty { grid(found) }
        if search.isEmpty, !catalog.isEmpty {
            ForEach(categories) { c in
                let all = catalog.skills(in: c.id)
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    DirectorySectionTitle(title: Text(verbatim: c.title), id: "skills.section.\(c.id)", count: all.count,
                                          action: all.count > Self.preview ? { category = c.id; browsing = true } : nil)
                        .directoryInset()
                    grid(Array(all.prefix(Self.preview)))
                }
            }
            DirectoryBrowseAll(title: CopyText(CopyKey("skills.browseAll"), skillCount), id: "skills.browseAll") {
                category = nil; browsing = true
            }
            if SkillsCatalog.notice != nil {
                Button { showingNotice = true } label: {
                    Text(CopyKey("skills.catalog.notice")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .directoryInset()
                .probeID("skills.catalog.notice")
            }
        }
    }

    private func grid(_ skills: [SkillsCatalog.Skill]) -> some View {
        DirectoryGrid {
            ForEach(skills) { s in
                CatalogSkillRow(skill: s, installed: library.skills.contains { $0.name == s.name },
                                installing: library.installing.contains(s.id), error: library.catalogErrors[s.id]) {
                    Task { await library.installFromCatalog(s) }
                }
            }
        }
    }
}

/// A skill of the catalogue: icon, title, one line (what it does; why a download failed) and `+` to install — a
/// spinner while its files download, a check mark once a skill of that name is installed.
struct CatalogSkillRow: View {
    let skill: SkillsCatalog.Skill
    let installed: Bool
    let installing: Bool
    var error: String?
    let onInstall: () -> Void

    /// The tile's glyph, by category (the index has no icons).
    static let symbols = ["writing": "pencil.line", "marketing": "megaphone", "sales": "person.2", "business": "briefcase",
                          "finance": "banknote", "data": "chart.bar", "research": "book", "people": "person.crop.circle",
                          "legal": "scroll", "product": "paintbrush", "planning": "checklist"]

    var body: some View {
        DirectoryRow(title: skill.title, detail: error ?? skill.summary, detailColor: error == nil ? .textSecondary : .warning,
                     detailID: error == nil ? nil : "skills.catalog.error.\(skill.name)") {
            Image(systemName: Self.symbols[skill.category] ?? "sparkles").font(.system(size: 18)).foregroundStyle(Color.textPrimary)
        } trailing: {
            if installed {
                Image(systemName: "checkmark").font(.system(size: 14)).foregroundStyle(Color.textSecondary)
                    .accessibilityLabel(Text(CopyKey("skills.card.installed")))
                    .probeID("skills.catalog.installed.\(skill.name)")
            } else if installing {
                ProgressView().controlSize(.small).probeID("skills.catalog.installing.\(skill.name)")
            } else {
                DirectoryGlyphButton(symbol: "plus", label: "\(CopyKey("skills.review.install").string()) \(skill.title)",
                                     id: "skills.catalog.add.\(skill.name)", action: onInstall)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: skill.title))
        .probeID("skills.catalog.row.\(skill.name)")
    }
}

/// Where the catalogue's skills come from and under which licences (tools/skills/NOTICE.md, bundled).
private struct SkillsNoticeSheet: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("skills.catalog.notice")).typeStyle(.headline)
            ScrollView {
                Text(verbatim: SkillsCatalog.notice ?? "").typeStyle(.code).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.space2)
            }
            .frame(height: 360)
            .background(Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            HStack {
                Spacer()
                Button(action: onDone) { Text(CopyKey("panel.close")) }.keyboardShortcut(.defaultAction)
                    .probeID("skills.catalog.notice.close")
            }
        }
        .padding(Spacing.space4)
        .frame(width: 560)
    }
}
