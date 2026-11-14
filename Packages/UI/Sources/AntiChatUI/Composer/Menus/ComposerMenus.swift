// State of the composer's + menu, inline `/` / `@` menu and sticky chips (M1.T17; R-013; IS-6, ChatGPT F-027).
// One per ComposerModel (`model.menus`). The host sets `context` (packs, switches, active model, registry tools;
// ChatSessions); the text view reports text/caret changes (`update`) and routes ↑ ↓ Return Tab Esc here while the
// inline menu is open (`handleKey`); the views (AddMenu, SlashAtMenu, ToolChipView) read and call it.
//   + (AddMenu): opens on click, lists `SlashCommandRegistry.addItems`; disabled rows stay listed with their reason.
//   / at the input start and @ at a word start (TriggerDetector): the same items plus the registry tools
//     (`menuItems`), fuzzy-filtered by what follows the trigger (CommandPaletteKit `paletteFuzzyScore`, P-shell-06);
//     ↑/↓ wrap around, Return or Tab picks, Esc closes until the trigger is typed again. `@` followed by a path
//     (`@~/…`, `@/…`) browses files instead (ported Osaurus AtFileMenu).
//   A pick removes the trigger text, then: a chip item adds a sticky chip (ToolChipsModel), Add photos & files opens
//   the file picker, a pack that is installed but off opens Settings → Capabilities; other disabled rows do nothing.
import AntiChatDesign
import AntiChatHarness
import AntiChatKnowledge
import AppKit
import CommandPaletteKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
public final class ComposerMenus {
    /// What the menus are built from. The default is the M1 launch state with no model (no tool entries).
    public var context = ComposerMenuContext(activeModelKey: "") {
        didSet { if context != oldValue { rebuild() } }
    }
    public private(set) var addItems: [ComposerMenuItem] = []
    public private(set) var menuItems: [ComposerMenuItem] = []
    public let chips = ToolChipsModel()

    // MARK: + menu
    /// M7.T06 step 7: the + menu's Connections row opens the per-chat server toggles (ConnectionsSubmenu).
    public var isConnectionsMenuOpen = false
    /// M7.T12 (R-082 AC3): the + menu's Skills row opens the per-chat skill switches (SkillsSubmenu).
    public var isSkillsMenuOpen = false
    /// M7.T14 (R-268 AC2): the + menu's Tools row opens the per-chat tool switches (ToolsSubmenu).
    public var isToolsMenuOpen = false
    public var isAddMenuOpen = false {
        didSet { if isAddMenuOpen { addSelection = 0; inlineDismissedAt = trigger?.location } }
    }
    public var addSelection = 0

    // MARK: Inline menu
    public private(set) var trigger: ComposerTrigger?
    /// Esc closed the menu for the trigger at this offset; it stays closed until that trigger goes away.
    private var inlineDismissedAt: Int?
    public var selection = 0
    /// Path mode (`@~/…`): the latest listing for `trigger.query`.
    public private(set) var fileResult: AtFileMenuResult?
    /// Horizontal caret offset of the trigger inside the text view (reported by the text view; menu anchor).
    public var anchorX: CGFloat = 0

    // MARK: Hooks
    /// Replaces a UTF-16 range of the composer text (the text view registers it, so undo works); nil = no editor.
    @ObservationIgnored public var replaceText: (@MainActor (NSRange, String) -> Void)?
    /// Adds picked files to the composer tray (ComposerModel binds it).
    @ObservationIgnored public var addFiles: (@MainActor ([URL]) -> Void)?
    /// M7.T03 step 2: Web search is off → the consent sheet; `done(true)` = turned on (then the chip is added).
    @ObservationIgnored public var requestWebConsent: (@MainActor (_ done: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Opens Settings → Capabilities (the view binds SwiftUI's `openSettings`).
    @ObservationIgnored public var openSettings: (@MainActor () -> Void)?
    /// The file picker; replaceable in tests and probes. Default: an NSOpenPanel for files (multiple).
    @ObservationIgnored public var chooseFiles: (@MainActor () -> [URL])? = nil
    /// Every pick, for probes and tests.
    public private(set) var lastPicked: String?
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var lastText = ""

    public init() { rebuild() }

    private func rebuild() {
        addItems = SlashCommandRegistry.addItems(context)
        menuItems = SlashCommandRegistry.menuItems(context)
        chips.available = menuItems
    }

    // MARK: Inline state

    public var isPathMode: Bool { trigger?.key == .at && AtFileMenu.isPathQuery(trigger?.query ?? "") }

    public var isInlineOpen: Bool {
        guard let t = trigger else { return false }
        return t.location != inlineDismissedAt && !isAddMenuOpen
    }

    /// The inline menu's rows (tool list mode).
    public var inlineItems: [ComposerMenuItem] {
        guard let t = trigger, !isPathMode else { return [] }
        return SlashCommandRegistry.filtered(menuItems, query: t.query, title: Self.title, scorer: paletteFuzzyScore)
    }

    public var fileItems: [AtFileItem] { isPathMode ? fileResult?.items ?? [] : [] }

    private var inlineCount: Int { isPathMode ? fileItems.count : inlineItems.count }

    /// Called by the text view on every text or selection change.
    public func update(text: String, caret: Int, hasMarkedText: Bool = false) {
        lastText = text
        let t = TriggerDetector.detect(text: text, caret: caret, hasMarkedText: hasMarkedText)
        if hasMarkedText, trigger != nil { return }  // keep the menu while an IME composes inside the query
        guard t != trigger else { return }
        if t?.location != trigger?.location || t?.key != trigger?.key { inlineDismissedAt = nil }
        if t == nil { inlineDismissedAt = nil }
        trigger = t
        selection = 0
        refreshFiles()
    }

    /// Esc.
    public func dismissInline() { inlineDismissedAt = trigger?.location }

    /// ↓ / ↑ with wrap-around (IS-6: "keyboard-navigable with wrap-around").
    public func move(_ delta: Int) {
        let n = inlineCount
        guard n > 0 else { return }
        selection = ((selection + delta) % n + n) % n
    }

    public func moveAdd(_ delta: Int) {
        let n = addItems.count
        guard n > 0 else { return }
        addSelection = ((addSelection + delta) % n + n) % n
    }

    /// Keys the text view routes here while the inline menu is open. Returns true when handled.
    public enum Key { case up, down, pick, escape }

    public func handleKey(_ key: Key) -> Bool {
        guard isInlineOpen else { return false }
        switch key {
        case .up: move(-1); return true
        case .down: move(1); return true
        case .escape: dismissInline(); return true
        case .pick:
            guard inlineCount > 0 else { return false }  // "No matches": Return sends as usual
            if isPathMode { pickFile(fileItems[min(selection, fileItems.count - 1)]) } else {
                pickInline(inlineItems[min(selection, inlineItems.count - 1)])
            }
            return true
        }
    }

    // MARK: Picks

    /// A row of the inline menu (click or Return).
    public func pickInline(_ item: ComposerMenuItem) {
        guard item.state.isPickable || item.state.isSettingsLink else { return }
        removeTriggerText()
        perform(item)
    }

    /// A row of the + menu.
    public func pickAdd(_ item: ComposerMenuItem) {
        guard item.state.isPickable || item.state.isSettingsLink else { return }
        isAddMenuOpen = false
        perform(item)
    }

    public func pickAddSelection() {
        guard addItems.indices.contains(addSelection) else { return }
        pickAdd(addItems[addSelection])
    }

    private func perform(_ item: ComposerMenuItem) {
        lastPicked = item.id
        if item.state.isSettingsLink {
            openSettings?()
            return
        }
        if item.state == .needsConsent {
            // M7.T03 step 2: the off → on transition asks first; Not now leaves it off (no chip).
            requestWebConsent? { [weak self] on in
                guard on, let self else { return }
                let enabled = ComposerMenuItem(id: item.id, kind: item.kind, group: item.group, state: .enabled, symbol: item.symbol,
                                               name: item.name, detail: item.detail)
                self.chips.add(enabled)
            }
            return
        }
        if case .action(.connections) = item.kind {
            isConnectionsMenuOpen = true  // M7.T06: per-chat server toggles, no chip
        } else if case .action(.skills) = item.kind {
            isSkillsMenuOpen = true  // M7.T12: per-chat skill switches, no chip
        } else if case .action(.tools) = item.kind {
            isToolsMenuOpen = true  // M7.T14: per-chat tool switches, no chip
        } else if item.makesChip {
            chips.add(item)
        } else if case .action(.files) = item.kind {
            if let chooseFiles {
                let urls = chooseFiles()
                if !urls.isEmpty { addFiles?(urls) }
            } else {
                Self.openPanel { [weak self] urls in if !urls.isEmpty { self?.addFiles?(urls) } }
            }
        }
    }

    /// A row of the path list: a folder completes the path (the menu stays open), a file joins the tray.
    public func pickFile(_ file: AtFileItem) {
        guard let t = trigger else { return }
        if file.isDirectory {
            let completed = Self.completedPath(query: t.query, name: file.name)
            let queryRange = NSRange(location: t.location + 1, length: (t.query as NSString).length)
            edit(queryRange, completed)
        } else {
            removeTriggerText()
            lastPicked = file.path
            addFiles?([URL(fileURLWithPath: file.path)])
        }
    }

    /// The query with its last partial component replaced by `name/` ("~/Doc" + "Documents" → "~/Documents/").
    nonisolated static func completedPath(query: String, name: String) -> String {
        if query.hasSuffix("/") { return query + name + "/" }
        guard let slash = query.lastIndex(of: "/") else { return query + "/" + name + "/" }  // "~" → "~/name/"
        return String(query[...slash]) + name + "/"
    }

    private func removeTriggerText() {
        guard let t = trigger else { return }
        edit(TriggerDetector.removalRange(t, in: lastText) ?? t.range, "")
        inlineDismissedAt = nil
        trigger = nil
    }

    private func edit(_ range: NSRange, _ replacement: String) {
        if let replaceText { replaceText(range, replacement) }
    }

    private func refreshFiles() {
        listing?.cancel()
        guard isPathMode, let query = trigger?.query else { fileResult = nil; return }
        listing = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                AtFileMenu.list(query: query, rootPath: nil)
            }.value
            guard !Task.isCancelled, let self, self.trigger?.query == query else { return }
            self.fileResult = result
            if self.selection >= result.items.count { self.selection = 0 }
        }
    }

    /// M6.T01 step 7: the open panel as a sheet on the key window (`beginSheetModal`), multi-select, limited to the
    /// supported set (R-020 AC2). Without a window it runs as an app-modal panel.
    private static func openPanel(_ done: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = supportedTypes
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { done(response == .OK ? panel.urls : []) }
            }
        } else {
            done(panel.runModal() == .OK ? panel.urls : [])
        }
    }

    /// The R-020 AC2 set (+ XLS, audio) for the open panel.
    static let supportedTypes: [UTType] = {
        var types: [UTType] = AttachmentKind.allCases.filter(\.isSupported).map(\.utType)
        types += AttachmentKind.codeExtensions.compactMap { UTType(filenameExtension: $0) }
        types += [.sourceCode, .text]
        return Array(Set(types))
    }()

    // MARK: Copy

    /// The row title: `add.*` for the + entries, the function name for a tool.
    nonisolated public static func title(_ item: ComposerMenuItem) -> String {
        if item.id == ToolChipsModel.readURLID { return CopyKey("search.readUrl").string() }  // M7.T03
        return switch item.kind {
        case .tool(let name), .skill(let name): name
        case .action(let a): titleKey(a).string()
        }
    }

    nonisolated public static func titleKey(_ a: ComposerMenuItem.Action) -> CopyKey {
        switch a {
        case .files: CopyKey("add.files")
        case .image: CopyKey("add.image")
        case .video: CopyKey("add.video")
        case .web: CopyKey("add.web")
        case .connections: CopyKey("add.connections")
        case .skills: CopyKey("add.skills")
        case .tools: CopyKey("add.tools")
        case .project: CopyKey("add.project")
        }
    }

    /// The grey second line of a disabled row (the universal "disabled says why" rule), or nil.
    nonisolated public static func reason(_ state: ComposerMenuItem.State) -> CopyText? {
        switch state {
        case .enabled: nil
        case .needsPack(let pack): CopyText(CopyKey("add.disabled.pack"), ["pack": packName(pack)])
        case .needsEnable: CopyText(CopyKey("add.disabled.enable"))
        case .notYet: CopyText(CopyKey("add.disabled.soon"))
        case .needsConsent: nil
        case .offline: CopyText(CopyKey("add.disabled.offline"))
        case .notOnThisMac(let key, let args): CopyText(CopyKey(key), args)
        }
    }

    nonisolated static func packName(_ pack: String) -> String {
        switch pack {
        case "photo": CopyKey("onb.pack.photo.name").string()
        case "video": CopyKey("onb.pack.video.name").string()
        case "voice": CopyKey("onb.pack.voice.name").string()
        default: CopyKey("onb.pack.chat.name").string()
        }
    }
}

extension ComposerMenuItem.State {
    /// Installed but off: the row is a link to Settings → Capabilities (step 1).
    /// M2.T21 (R-202 AC3): an uninstalled pack's row also opens Settings › Capabilities ("Enable in Settings").
    var isSettingsLink: Bool {
        switch self {
        case .needsEnable, .needsPack: true
        default: false
        }
    }
}
