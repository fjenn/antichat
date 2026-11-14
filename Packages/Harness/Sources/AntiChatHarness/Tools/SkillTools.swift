// M7.T12 steps 3–6 (R-082 AC2–AC4; G-034) + M7.T13 (R-262–R-265): skills in the turn.
//   - Explicit use (a "/" chip `skill:<name>`) and "Apply to every chat" put the skill's SKILL.md body in the prompt's
//     stable layer `skills` (after memory, before the tool block): the user chose it, so it stays for the chat.
//   - Automatic use is progressive disclosure (M7.T13): the other skills that are on in this chat are ranked by
//     SkillSelector; the top M(tier) appear only as `name: description` lines (`<available_skills>`, volatile tail of
//     the newest user turn) and a body joins the turn only through `load_skill(name)` — or, on a pre-load tier, when
//     the top similarity is ≥ θ (`skill_preload` event). Bodies are cut to `body_tokens(tier)`, at most
//     `max_active(tier)` per turn (tier-budgets.json `skills`).
//   - A skill is on in a chat by its global switch, overridden per chat by `skill.on:<name>` / `skill.off:<name>` in
//     `chat.tools_json` ("+" → Skills ›; never touches the global switch, R-082 AC3).
//   - Every skill used leaves one activity line "Using skill {name} ▸" (▸ → "Turn off for this chat"; `skills.needs`
//     when its allowed-tools want web search or a connection that is off/offline, AC4). No network in the skill path.
//   - `create_skill` (R-264) drafts a SKILL.md the user installs from the reply's SkillInstallCard; `run_skill_script`
//     (R-265) exists only while SkillScriptPolicy.canRun.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatTools
import Foundation
import Synchronization

public struct ActiveSkill: Sendable, Hashable {
    public enum Reason: String, Sendable, Hashable { case explicit, applyAll, automatic, preload }
    public var name: String
    public var body: String
    public var reason: Reason
    public var needs: [SkillNeed]
    /// M7.T14 (B3 rule 8): the skill's `allowed-tools`, pre-selected for the turn (never past a permission).
    public var allowedTools: [String] = []
}

/// One turn's skills (M7.T13): what the prompt carries and what `load_skill` may still add.
public struct SkillTurnPlan: Sendable {
    public var tier: String
    /// Bodies in the stable `skills` layer (explicit chips, then Apply to every chat), at most `maxActive`.
    public var active: [ActiveSkill] = []
    /// The `<available_skills>` lines (top M of the other on-skills).
    public var manifest: [SkillSelector.Scored] = []
    /// Bodies pre-loaded into the volatile tail (pre-load tiers, top similarity ≥ θ).
    public var preloaded: [ActiveSkill] = []
    /// Every skill on in this chat (`load_skill` / `read_skill_file` may use these).
    public var available: [String] = []
    /// An on-skill has `scripts/` (R-265: `run_skill_script` only while canRun).
    public var hasScripts = false
    /// An on-skill has `references/` or `assets/` files (`read_skill_file` is offered only then: small models otherwise
    /// call it in place of `load_skill`).
    public var hasReferences = false
    public var bodyTokens: Int
    public var maxActive: Int
    /// `skill_preload name=… score=…` lines for the prompt dump (AT-262).
    public var events: [String] = []

    /// The stable layer text.
    public var stableText: String { SkillTools.block(active, budgetTokens: bodyTokens) }
    /// The volatile text after the time line: the manifest, then pre-loaded bodies.
    public var volatileText: String {
        ([SkillManifestBlock.render(manifest)] + preloaded.map { LoadSkillTool.element(name: $0.name, body: $0.body, budgetTokens: bodyTokens) })
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    /// Disclosure tools are offered (a manifest or a body that may point at references).
    public var offersLoad: Bool { !manifest.isEmpty || !preloaded.isEmpty || !active.isEmpty }
}

public enum SkillTools {
    /// The chip a "/" pick stores (`chat.tools_json`).
    public static func chipID(_ name: String) -> String { "skill:\(name)" }
    public static func onMarker(_ name: String) -> String { "skill.on:\(name)" }
    public static func offMarker(_ name: String) -> String { "skill.off:\(name)" }

    /// The skill name of a chip id, or nil.
    public static func skillName(chipID: String) -> String? {
        chipID.hasPrefix("skill:") ? String(chipID.dropFirst(6)) : nil
    }

    /// The process's store (set by `ToolRuntime.app` for the on-disk database; the Settings page and menus read it).
    nonisolated(unsafe) public private(set) static var store: SkillStore?

    /// Rollback switch (M7.T13): false = explicit use only (no manifest, no pre-load).
    public static let autoActivateKey = "skillsAutoActivate"
    public static var autoActivate: Bool { AppDefaults.standard.object(forKey: autoActivateKey) as? Bool ?? true }

    /// The app's selector: the shared embedding model (WebSearchTools' embedder, M2 Qwen3-Embedding), else lexical.
    public static let appSelector = SkillSelector(embed: { texts, query in
        guard let e = WebSearchTools.embedder else { return nil }
        return try? await e.embed(texts, kind: query ? .query : .document)
    })

    /// Opens the store next to `database`, copies the starter skills on first use, and reconciles rows with folders.
    @discardableResult
    public static func install(store given: SkillStore) -> SkillStore {
        do {
            try StarterSkills.installIfNeeded(into: given)
            try given.reconcile()
        } catch {
            AppLog.log(.tools, .error, "skills: starter install / reconcile failed: \(error)")
        }
        store = given
        NotificationCenter.default.post(name: didChange, object: nil)
        return given
    }

    /// Posted after the installed set or a switch changed (menus rebuild).
    public static let didChange = Notification.Name("AntiChatSkillsDidChange")

    /// On in a chat whose `chat.tools_json` ids are `ids`.
    public static func isOn(_ s: InstalledSkill, in ids: [String]) -> Bool {
        guard s.isValid else { return false }
        if ids.contains(offMarker(s.name)) { return false }
        if ids.contains(onMarker(s.name)) { return true }
        return s.record.enabled
    }

    static func cell<T>(_ map: [String: T]?, _ tier: String, _ fallback: T) -> T { map?[tier] ?? fallback }

    /// Eval-only overrides of the tier budgets (`antichat-bench skills-activation --theta/--m/--preload`, θ/M tuning).
    public struct Tuning: Sendable { public var theta: Double?; public var m: Int?; public var preload: Bool?
        public init(theta: Double? = nil, m: Int? = nil, preload: Bool? = nil) { self.theta = theta; self.m = m; self.preload = preload } }
    nonisolated(unsafe) public static var tuning: Tuning?

    /// The turn's plan (M7.T13 steps 1–3). `selector` nil or auto-activation off = explicit / Apply to every chat only.
    public static func plan(store: SkillStore, chatToolIDs ids: [String], userText: String?, tier: String,
                            webSearch: WebSearchAvailability.State, connections: [String: Bool] = [:],
                            selector: SkillSelector?, budgets: TierBudgets = .shared) async -> SkillTurnPlan {
        let b = budgets.skills
        var plan = SkillTurnPlan(tier: tier, bodyTokens: cell(b?.bodyTokens, tier, 1500), maxActive: max(1, cell(b?.maxActive, tier, 1)))
        let installed = store.list()
        let on = installed.filter { isOn($0, in: ids) && $0.document != nil }
        plan.available = on.map(\.name)
        plan.hasScripts = on.contains(where: \.hasScripts)
        plan.hasReferences = on.contains { $0.files.contains { $0.relativePath.hasPrefix("references/") || $0.relativePath.hasPrefix("assets/") } }
        var seen = Set<String>()
        func make(_ s: InstalledSkill, _ reason: ActiveSkill.Reason) -> ActiveSkill? {
            guard let doc = s.document, seen.insert(s.name).inserted else { return nil }
            return ActiveSkill(name: s.name, body: doc.body, reason: reason,
                               needs: SkillNeeds.evaluate(allowedTools: doc.allowedTools, webSearch: webSearch, connections: connections),
                               allowedTools: doc.allowedTools)
        }
        let explicit = Set(ids.compactMap(skillName(chipID:)))
        for s in on where explicit.contains(s.name) { if let a = make(s, .explicit) { plan.active.append(a) } }
        for s in on where s.record.applyAll { if let a = make(s, .applyAll) { plan.active.append(a) } }
        plan.active = Array(plan.active.prefix(plan.maxActive))
        guard let selector, autoActivate, let text = userText, !text.isEmpty else { return plan }
        let rest = on.filter { !seen.contains($0.name) }
        let m = min(tuning?.m ?? cell(b?.candidatesM, tier, 2), 100)
        let top = await selector.topM(text, candidates: rest, m: m, store: store)
        plan.manifest = top
        let theta = tuning?.theta ?? cell(b?.theta, tier, 0.5)
        let preloadTier = tuning?.preload ?? b?.preload?[tier] ?? (tier == "T0")
        if preloadTier, let best = top.first, best.semantic, best.score >= theta, plan.active.count < plan.maxActive,
           let s = rest.first(where: { $0.name == best.name }), let a = make(s, .preload) {
            plan.preloaded = [a]
            plan.manifest.removeAll { $0.name == best.name }
            plan.events.append("skill_preload name=\(best.name) score=\(String(format: "%.3f", best.score)) theta=\(theta)")
        }
        return plan
    }

    /// The `skills` layer: each body in a `<skill>` element, cut to `budgetTokens` (0 = uncut).
    public static func block(_ skills: [ActiveSkill], budgetTokens: Int = 0) -> String {
        skills.map { LoadSkillTool.element(name: $0.name, body: $0.body, budgetTokens: budgetTokens) }.joined(separator: "\n\n")
    }

    /// The activity line of an active skill.
    public static func activity(_ s: ActiveSkill) -> ToolActivity {
        ToolActivity(kind: .skill, id: "skill:\(s.name)", tool: s.name, state: .done,
                     result: s.needs.isEmpty ? nil : s.needs.map(\.token).joined(separator: "\n"))
    }

    // MARK: - Tools (M7.T13)

    /// What `load_skill` may do in one turn (keyed by the reply id, `TurnContext.requestID`).
    struct Ledger: Sendable {
        var store: SkillStore
        var available: Set<String>
        var loaded: [String]
        var limit: Int
        var budget: Int
    }

    static let ledgers = Mutex<[String: Ledger]>([:])

    /// TurnController: the turn's plan becomes what its `load_skill` calls may load.
    public static func begin(turn: String, plan: SkillTurnPlan, store: SkillStore) {
        let loaded = plan.active.map(\.name) + plan.preloaded.map(\.name)
        ledgers.withLock {
            $0[turn] = Ledger(store: store, available: Set(plan.available), loaded: loaded, limit: plan.maxActive, budget: plan.bodyTokens)
        }
    }

    public static func end(turn: String) { _ = ledgers.withLock { $0.removeValue(forKey: turn) } }

    /// Skills loaded so far in `turn` (tests, AT-262).
    public static func loaded(turn: String) -> [String] { ledgers.withLock { $0[turn]?.loaded ?? [] } }

    /// `load_skill`: the body of an on-skill as a `<skill>` element (cut to the tier budget), within `max_active`.
    public static func loadTool() -> RegisteredTool {
        RegisteredTool(name: LoadSkillTool.name, description: LoadSkillTool.description, parametersJSON: LoadSkillTool.parametersJSON,
                       sideEffect: .read, outputIsUntrusted: true) { args in
            guard let name = LoadSkillTool.skillName(args), !name.isEmpty else { throw ToolRunError("load_skill needs {\"name\": \"<skill name>\"}.") }
            guard let turn = TurnContext.requestID, let l = ledgers.withLock({ $0[turn] }) else {
                throw ToolRunError("No skills are available in this chat.")
            }
            if l.loaded.contains(name), let body = l.store.body(of: name) {
                return LoadSkillTool.element(name: name, body: body, budgetTokens: l.budget)
            }
            guard l.available.contains(name), let body = l.store.body(of: name) else {
                throw ToolRunError("No skill named \(name) is on in this chat. Available: \(l.available.sorted().joined(separator: ", ")).")
            }
            guard l.loaded.count < l.limit else {
                throw ToolRunError("At most \(l.limit) skill(s) per reply on this Mac (loaded: \(l.loaded.joined(separator: ", "))). Answer with those.")
            }
            ledgers.withLock { $0[turn]?.loaded.append(name) }
            return LoadSkillTool.element(name: name, body: body, budgetTokens: l.budget)
        }
    }

    /// `read_skill_file`: a text file of an on-skill's references/ or assets/.
    public static func readFileTool() -> RegisteredTool {
        RegisteredTool(name: ReadSkillFileTool.name, description: ReadSkillFileTool.description,
                       parametersJSON: ReadSkillFileTool.parametersJSON, sideEffect: .read, outputIsUntrusted: true) { args in
            guard let turn = TurnContext.requestID, let l = ledgers.withLock({ $0[turn] }) else {
                throw ToolRunError("No skills are available in this chat.")
            }
            // A model that asks for the skill's own SKILL.md means load_skill (counted and cut the same way).
            if let path = ReadSkillFileTool.path(args), path.isEmpty || path == "SKILL.md", let name = LoadSkillTool.skillName(args) {
                return try await loadTool().run(#"{"name":"\#(name)"}"#)
            }
            do { return try ReadSkillFileTool.read(args, store: l.store, allowed: { l.available.contains($0) }) } catch {
                throw ToolRunError("\(error)")
            }
        }
    }

    /// `create_skill` (R-264): validated before it runs (one repair turn); the run only answers that the card is shown.
    public static func createTool(store: @escaping @Sendable () -> SkillStore?) -> RegisteredTool {
        RegisteredTool(name: CreateSkillTool.name, description: CreateSkillTool.description,
                               parametersJSON: CreateSkillTool.parametersJSON, sideEffect: .read, outputIsUntrusted: false,
                               validate: { args in
                                   CreateSkillTool.problems(args, existing: Set((store()?.list() ?? []).map(\.name)))
                               }) { args in
            guard let d = CreateSkillTool.draft(args) else { throw ToolRunError("create_skill needs {\"name\", \"description\", \"body\"}.") }
            return CreateSkillTool.result(d)
        }
    }

    /// `run_skill_script` (R-265): registered only while `policy.canRun`; asks every time (side effect `.write`).
    public static func scriptTool(store: SkillStore, policy: SkillScriptPolicy) -> RegisteredTool {
        RegisteredTool(name: RunSkillScriptTool.name, description: RunSkillScriptTool.description,
                       parametersJSON: RunSkillScriptTool.parametersJSON, sideEffect: .write, outputIsUntrusted: true) { args in
            guard let chat = TurnContext.chatID else { throw ToolRunError("no chat") }
            do {
                return try await RunSkillScriptTool.run(args, store: store, policy: policy, runner: SkillScriptPolicy.runner, chatID: chat)
            } catch let e as ToolRunError { throw e } catch { throw ToolRunError("\(error)") }
        }
    }

    /// The disclosure + create tools in `registry` (idempotent); `run_skill_script` registered or removed per policy.
    public static func ensureTools(in registry: ToolRegistry, store: SkillStore, policy: SkillScriptPolicy, scripts: Bool) {
        if registry.tool(named: LoadSkillTool.name) == nil { registry.register(loadTool()) }
        if registry.tool(named: ReadSkillFileTool.name) == nil { registry.register(readFileTool()) }
        if registry.tool(named: CreateSkillTool.name) == nil { registry.register(createTool(store: { store })) }
        if scripts && policy.canRun {
            if registry.tool(named: RunSkillScriptTool.name) == nil { registry.register(scriptTool(store: store, policy: policy)) }
        } else {
            registry.unregister(RunSkillScriptTool.name)
        }
    }

    /// The names of the skill tools (TurnController keeps them out of the pruner's count).
    public static let toolNames: Set<String> = [LoadSkillTool.name, ReadSkillFileTool.name, CreateSkillTool.name, RunSkillScriptTool.name]

    /// The request asks for a new skill ("build me a skill that …", "save this as a skill"): `create_skill` is offered
    /// even where the pruner would leave it out (a cue on the request's words, like MediumCue; not a content check).
    public static func createCue(_ text: String?) -> Bool {
        guard let t = text?.lowercased() else { return false }
        return t.range(of: #"\b(create|build|make|write|save|turn)\b[^.?!]{0,80}\bskills?\b"#, options: .regularExpression) != nil
    }
}
