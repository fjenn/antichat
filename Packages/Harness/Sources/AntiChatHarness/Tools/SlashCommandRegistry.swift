// Composer menu registry (M1.T17 steps 1–2; R-013; G-006, P-shell-06 RL-005 IMPROVE).
// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Managers/SlashCommandRegistry.swift (MIT): one list
// merged from several sources (Osaurus: built-ins → custom commands → skills; AntiChat: the + actions → the tool registry),
// deduplicated by id, and the popup filter (score, then name; an empty query keeps the default order).
// Changes from upstream: a value type instead of the `@MainActor` singleton (no disk-backed custom commands; skills are
// M7), items carry an availability state (pack missing / pack off / not yet) instead of being dropped, and the score is
// injected so the UI can use CommandPaletteKit's fuzzy scorer (P-shell-06; the upstream exact/prefix/substring score
// stays the default). The same list backs the + menu, `/` at the input start and `@` anywhere (IS-6: the meaning of
// a trigger never changes by mode).
// D-023 (a): while the active chat model is chat-only (`ModelToolCapability.offersToolChips` false, the starter
// `chat-0.8b`) the list has no tool entries: no registry tools, no Web search, no Connections.
import AntiChatFoundation
import AntiChatTools
import Foundation

/// One row of the + / slash / @ menus.
public struct ComposerMenuItem: Sendable, Hashable, Identifiable {
    /// The + menu's fixed entries (components.md AddMenu, copy `add.*`).
    public enum Action: String, Sendable, Hashable, CaseIterable {
        case files, image, video, web, connections, project
        /// M7.T12 (R-082 AC3): "+" → Skills › per-chat switches (no chip).
        case skills
    }

    public enum Kind: Sendable, Hashable {
        case action(Action)
        /// A registry tool (M1.T16 `ToolRegistry`), by function name.
        case tool(name: String)
        /// M7.T12 (R-082 AC2): an installed skill, picked with "/" for explicit use (chip `skill:<name>`).
        case skill(name: String)
    }

    /// Why a listed row cannot be used now. Neither state hides the row (step 1).
    public enum State: Sendable, Hashable {
        case enabled
        /// The pack is not installed: `add.disabled.pack` ("Install {pack} to use this").
        case needsPack(String)
        /// The pack is installed but turned off: `add.disabled.enable` ("Enable in Settings"); picking it opens
        /// Settings → Capabilities.
        case needsEnable(String)
        /// Arrives in a later milestone (Use project, M8): `add.disabled.soon`.
        case notYet
        /// M7.T03 (R-080 AC1): Web search is switched off; picking it asks for consent (WebSearchConsentSheet) and,
        /// once accepted, turns search on and adds the chip.
        case needsConsent
        /// M7.T03 (R-080 AC4): Offline only or no network: `add.disabled.offline`; the chip shows `net.offlineShort`
        /// and the reply answers from local knowledge with `network.offlineForSearch`.
        case offline
        /// M5.T08 (R-046 AC1): this Mac cannot run the pack (Video on T0–T1): disabled, the tooltip and grey line are
        /// the dimmed reason (copy key + args, e.g. `onb.pack.dimmed.ram` {gb: 24}); never hidden, never a link.
        case notOnThisMac(reasonKey: String, args: [String: String])

        public var isEnabled: Bool { self == .enabled }
        /// The row can still be picked (consent first / a chip that waits for the network).
        public var isPickable: Bool { self == .enabled || self == .needsConsent || self == .offline }
    }

    public enum Group: String, Sendable, Hashable { case add, tools, skills }

    /// Stable id, also the sticky-chip id stored in `chat.tools_json`: the action's raw value, or `tool:<name>`.
    public let id: String
    public let kind: Kind
    public let group: Group
    public let state: State
    /// SF Symbol.
    public let symbol: String
    /// Tool function name (also its title), or nil for an action (titled by its `add.*` copy key in the UI).
    public let name: String?
    /// Tool description (the grey second line), or nil.
    public let detail: String?

    public init(id: String, kind: Kind, group: Group, state: State, symbol: String, name: String? = nil,
                detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.group = group
        self.state = state
        self.symbol = symbol
        self.name = name
        self.detail = detail
    }

    /// Picking the row adds a sticky ToolChip (step 3). Add photos & files opens the file picker instead; Use project
    /// opens the project picker (M8).
    public var makesChip: Bool {
        switch kind {
        case .tool, .skill: true
        case .action(let a): a == .image || a == .video || a == .web || a == .connections
        }
    }

    public static func toolID(_ name: String) -> String { "tool:\(name)" }
}

/// What the menus are built from: pack state, the M7 switches and the active chat model's tools.
public struct ComposerMenuContext: Sendable, Hashable {
    public struct Tool: Sendable, Hashable {
        public var name: String
        public var description: String
        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }

    /// Installed packs (`chat`, `voice`, `photo`, `video`, `files`).
    public var installedPacks: Set<String>
    /// Installed but turned off in Settings → Capabilities.
    public var disabledPacks: Set<String>
    /// M5.T08: packs this Mac cannot run, with the dimmed reason (copy key, args). Wins over "not installed".
    public var ineligiblePacks: [String: ComposerMenuItem.State] = [:]
    /// Web search is on (M7; hidden in M1 unless `-FakeWebSearchEnabled YES`).
    public var webSearchEnabled: Bool
    /// M7.T03: the live web search state (switch, Offline only, path); nil = the M1 flag above decides.
    public var webSearch: WebSearchAvailability.State?
    /// At least one connection is on (M7; hidden in M1 unless `-FakeConnectionsEnabled YES`).
    public var connectionsEnabled: Bool
    /// The active chat model's catalog key (D-023).
    public var activeModelKey: String
    /// Available registry tools.
    public var tools: [Tool]
    /// M7.T12: installed, valid skills that are on (the "/" Skills group; name + description).
    public var skills: [Tool] = []
    /// M7.T12: at least one valid skill is installed (the + menu's Skills › row).
    public var hasSkills = false

    public init(installedPacks: Set<String> = ["chat"], disabledPacks: Set<String> = [], webSearchEnabled: Bool = false,
                connectionsEnabled: Bool = false, activeModelKey: String, tools: [Tool] = []) {
        self.installedPacks = installedPacks
        self.disabledPacks = disabledPacks
        self.webSearchEnabled = webSearchEnabled
        self.webSearch = webSearchEnabled ? .available : nil
        self.connectionsEnabled = connectionsEnabled
        self.activeModelKey = activeModelKey
        self.tools = tools
    }

    /// DEBUG `-FakePackState photo=ready|absent|downloading` (M4.T16) also decides the menus' rows: `ready` is
    /// installed and on, the others not installed. Q-015 r4: the menus read only the live install state, so in a UI
    /// test container with `photo=ready` (the image job ran) Create image was "Install Photo" and opened Settings.
    public static func applyFakePackStates(_ options: LaunchOptions = .current, installed: inout Set<String>,
                                           disabled: inout Set<String>) {
        for (pack, state) in options.fakePackStates {
            let p = pack.lowercased()
            if state == "ready" { installed.insert(p); disabled.remove(p) } else { installed.remove(p); disabled.remove(p) }
        }
    }

    /// M1: chat only, unless the DEBUG `-FakeInstalledPacks` / `-FakeDisabledPacks` / `-FakeWebSearchEnabled` /
    /// `-FakeConnectionsEnabled` options say otherwise (M1.md convention 10; M2's capability manager replaces it).
    public static func launch(options: LaunchOptions = .current, activeModelKey: String,
                              registry: ToolRegistry?) -> ComposerMenuContext {
        var installed: Set<String> = ["chat"]
        installed.formUnion((options.fakeInstalledPacks ?? []).map { $0.lowercased() })
        var disabled = Set((options.fakeDisabledPacks ?? []).map { $0.lowercased() }).intersection(installed)
        applyFakePackStates(options, installed: &installed, disabled: &disabled)
        let tools = (registry?.all ?? []).filter(\.isAvailable).filter { !WebSearchTools.names.contains($0.name) }
            .filter { !$0.key.hasPrefix("mcp:") }  // M7.T06: connection tools live under Connections
            .map { Tool(name: $0.name, description: $0.description) }
        var c = ComposerMenuContext(installedPacks: installed, disabledPacks: disabled,
                                    webSearchEnabled: options.fakeWebSearchEnabled,
                                    connectionsEnabled: options.fakeConnectionsEnabled,
                                    activeModelKey: activeModelKey, tools: tools)
        // M7.T03: the app registry carries web_search → the + menu's Web search row follows the live state.
        // (`-FakeWebSearchEnabled YES`, the M1 menu fixtures, keeps the row on whatever the network state.)
        // M7.T06: the Connections row appears once the user has added a connection with tools.
        if !MCPTools.shared.all.isEmpty { c.connectionsEnabled = true }
        if registry?.tool(named: "web_search") != nil, !options.fakeWebSearchEnabled {
            c.webSearch = webSearchState()
            c.webSearchEnabled = true
        }
        c.loadSkills()
        return c
    }

    /// M7.T12: the installed skills now (skills are instructions, so they are listed for every model, chat-only too).
    public mutating func loadSkills(_ store: SkillStore? = SkillTools.store) {
        let valid = (store?.list() ?? []).filter(\.isValid)
        hasSkills = !valid.isEmpty
        skills = valid.filter { $0.record.enabled }.map { Tool(name: $0.name, description: $0.description) }
    }

    /// The menu state of Web search now (the gate's switch, Offline only, the path).
    public static func webSearchState(_ a: WebSearchAvailability = WebSearchAvailability()) -> WebSearchAvailability.State { a.state }

    var webItemState: ComposerMenuItem.State? {
        switch webSearch {
        case nil: nil
        case .available?: .enabled
        case .switchedOff?: .needsConsent
        case .offlineOnly?, .noNetwork?: .offline
        }
    }

    /// D-023 (a): tool chips and tool entries only for a model that may be offered tools.
    public var offersTools: Bool { ModelToolCapability.offersToolChips(activeModelKey: activeModelKey) }

    func packState(_ pack: String) -> ComposerMenuItem.State {
        if let s = ineligiblePacks[pack], case .notOnThisMac = s { return s }
        if !installedPacks.contains(pack) { return .needsPack(pack) }
        if disabledPacks.contains(pack) { return .needsEnable(pack) }
        return .enabled
    }
}

public enum SlashCommandRegistry {
    /// `(query, title) → score` (higher is better; nil = no match).
    public typealias Scorer = @Sendable (_ query: String, _ title: String) -> Int?

    /// The + menu: Add photos & files · Create image · Create video · Web search · Connections · Skills.
    public static func addItems(_ c: ComposerMenuContext) -> [ComposerMenuItem] {
        var items: [ComposerMenuItem] = [
            action(.files, .enabled, "paperclip"),
            action(.image, c.packState("photo"), "photo"),
            action(.video, c.packState("video"), "film"),
        ]
        if c.offersTools {
            if let web = c.webItemState { items.append(action(.web, web, "globe")) }
            // Always listed: with nothing connected yet the submenu is the way to Settings › Connections.
            items.append(action(.connections, .enabled, "puzzlepiece.extension"))
        }
        if c.hasSkills { items.append(action(.skills, .enabled, "sparkles")) }  // M7.T12
        return items
    }

    /// The `/` and `@` list: the + entries, then the registry tools (none for a chat-only model). Deduplicated by
    /// id, first wins (upstream `commands(for:)`).
    public static func menuItems(_ c: ComposerMenuContext) -> [ComposerMenuItem] {
        var seen = Set<String>()
        var result: [ComposerMenuItem] = []
        func append(_ item: ComposerMenuItem) {
            guard seen.insert(item.id).inserted else { return }
            result.append(item)
        }
        addItems(c).forEach(append)
        if c.offersTools {
            for t in c.tools.sorted(by: { $0.name < $1.name }) {
                append(ComposerMenuItem(id: ComposerMenuItem.toolID(t.name), kind: .tool(name: t.name), group: .tools,
                                        state: .enabled, symbol: "wrench.and.screwdriver", name: t.name,
                                        detail: t.description))
            }
        }
        // M7.T12 step 5: the "Skills" group — picking one adds its chip (explicit use).
        for sk in c.skills.sorted(by: { $0.name < $1.name }) {
            append(ComposerMenuItem(id: SkillTools.chipID(sk.name), kind: .skill(name: sk.name), group: .skills, state: .enabled,
                                    symbol: "sparkles", name: sk.name, detail: sk.description))
        }
        return result
    }

    /// Items matching `query`, best score first, then by title; an empty query returns `items` unchanged.
    public static func filtered(_ items: [ComposerMenuItem], query: String, title: (ComposerMenuItem) -> String,
                                scorer: Scorer = matchScore) -> [ComposerMenuItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items
            .compactMap { item -> (ComposerMenuItem, String, Int)? in
                let t = title(item)
                let best = [scorer(q, t), item.name.flatMap { scorer(q, $0) }].compactMap { $0 }.max()
                return best.map { (item, t, $0) }
            }
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 > rhs.2 }
                return lhs.1.localizedCaseInsensitiveCompare(rhs.1) == .orderedAscending
            }
            .map(\.0)
    }

    /// Upstream score: 3 = exact, 2 = prefix, 1 = substring, nil = no match (case-insensitive).
    public static let matchScore: Scorer = { query, title in
        let q = query.lowercased(), n = title.lowercased()
        if n == q { return 3 }
        if n.hasPrefix(q) { return 2 }
        if n.contains(q) { return 1 }
        return nil
    }

    private static func action(_ a: ComposerMenuItem.Action, _ state: ComposerMenuItem.State,
                               _ symbol: String) -> ComposerMenuItem {
        ComposerMenuItem(id: a.rawValue, kind: .action(a), group: .add, state: state, symbol: symbol)
    }
}
