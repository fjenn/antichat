// M2.T06 (R-222 AC1, R-239 AC1, R-298, R-295 install part, NFR-D3/D4; blueprint E §E.2.3; P-platform-02 selector
// part, design reference AlexsJones/llmfit@d52eac4). Pure and deterministic: catalog + hardware profile + choices →
// one model per pack × mode × role. No I/O, no network, no models; recomputed at every launch.
//   1. cell = assignments[tier/sub-band][speed class] (closest lower class when absent)
//   2. chat: primary, else its `step_down` when the primary is revoked / cannot run / does not fit / decodes
//      under 15 tok/s (SpeedGuard); context from the ladder (never silently below the cell default)
//   3. Evil chat: same rule on the Evil pick; never `chat_fast` (R-227), so a cell without an Evil pick is a reason
//   4. starter `chat_fast` on every tier, internal on T0–T2 (R-298); `title` resolves `@chat_fast` / `@chat`
//   5. embed every tier, rerank T2+ (on demand); voice/photo/video lists (Evil = Normal ids, Q-009 a)
//   6. overrides win when they fit (or always with allowOverBudget); unknown / revoked overrides are ignored
import Foundation

public struct ModelSelector: Sendable {
    public let catalog: ModelCatalog
    private let loadable: @Sendable (String) -> Bool

    /// `isLoadable` defaults to the catalog's own revocation + engine check (CatalogStore.isLoadable semantics).
    public init(catalog: ModelCatalog, isLoadable: (@Sendable (String) -> Bool)? = nil) {
        self.catalog = catalog
        let c = catalog
        self.loadable = isLoadable ?? { id in
            guard let m = c.models[id], c.revocation(for: id)?.action != .disable else { return false }
            return CatalogStore.isCompatible(m)
        }
    }

    public func select(profile: HardwareProfile, enabledPacks: Set<ModelPack> = Set(ModelPack.allCases),
                       modes: Set<ModelMode> = [.normal], overrides: [ModelOverride] = [], allowOverBudget: Bool = false) -> Selection {
        guard let (key, cell) = catalog.cell(tier: profile.tier, ramGB: profile.ramGB, speedClass: profile.speedClass) else {
            return Selection(cellKey: profile.tierKey, speedClass: profile.speedClass, slots: [])
        }
        let mustStay = ResidencyTable.mustStayGB(cell: cell, catalog: catalog, voiceEnabled: enabledPacks.contains(.voice))
        var slots: [SelectionSlot] = []
        let internalStarter = profile.tier <= .T2

        for mode in ModelMode.allCases where modes.contains(mode) {
            let pick = mode == .normal ? cell.chat.normal : cell.chat.evil
            let reason = mode == .normal ? cell.chat.normalReason : (cell.chat.evilReason ?? "evil_not_available")
            var slot = chatSlot(mode: mode, pick: pick, reason: reason, mustStay: mustStay, profile: profile, cell: cell)
            if let o = overrides.first(where: { $0.pack == .chat && $0.mode == mode }) {
                slot = apply(o, to: slot, mustStay: mustStay, profile: profile, allowOverBudget: allowOverBudget,
                             defaultCtx: pick?.ctx ?? 8192, evil: mode == .evil, fast: cell.chat.fastFirst)
            }
            slots.append(slot)
        }
        // Starter (R-298) and title alias.
        let fast = cell.chat.fastFirst
        let fastModel = loadable(fast) ? catalog.models[fast] : nil
        slots.append(SelectionSlot(pack: .chat, mode: .normal, role: "chat_fast", modelID: fastModel.map { _ in fast },
                                   installIDs: fastModel.map { _ in closure([fast]) } ?? [], ctx: fastModel?.contextDefault,
                                   fit: fastModel.map { FitRule.classify(residentGB: FitRule.resident($0, ctx: $0.contextDefault ?? 8192), mustStayGB: mustStay, profile: profile) },
                                   reason: fastModel == nil ? "revoked" : nil, notes: [], keepInternal: internalStarter))
        let titleID: String? = switch cell.title {
        case "@chat_fast": fastModel.map { _ in fast }
        case "@chat": slots.first { $0.role == "chat" && $0.mode == .normal }?.modelID
        default: loadable(cell.title) ? cell.title : nil
        }
        slots.append(SelectionSlot(pack: .chat, mode: .normal, role: "title", modelID: titleID, installIDs: [], ctx: nil, fit: nil,
                                   reason: titleID == nil ? "unavailable" : nil, notes: [], keepInternal: false))
        // Search roles belong to the Chat pack (both modes share them).
        for (role, id, why) in [("embed", cell.embed, cell.embedReason), ("rerank", cell.rerank, cell.rerankReason)] {
            slots.append(simpleSlot(pack: .chat, mode: .normal, role: role, ids: id.map { [$0] } ?? [], reason: why, mustStay: 0, profile: profile))
        }
        // AT-250 c2 (A-M7-T03c): the citation entailment model of web answers (Chat pack, on demand: `on_demand`).
        slots.append(simpleSlot(pack: .chat, mode: .normal, role: "cite_check", ids: cell.citeCheck.map { [$0] } ?? [],
                                reason: nil, mustStay: 0, profile: profile))
        // The detectors check Photo/Video outputs only: a cell with neither (T0) installs nothing for them.
        let hasMedia = !(cell.photo?.normal ?? []).isEmpty || !(cell.video?.normal ?? []).isEmpty
        slots.append(SelectionSlot(pack: .photo, mode: .normal, role: "csam_check", modelID: cell.csamCheck,
                                   installIDs: hasMedia ? (cell.csamCheck.map { closure([$0]) } ?? []) : [],
                                   ctx: nil, fit: nil, reason: cell.csamCheck == nil ? (cell.csamCheckReason ?? "pending") : nil, notes: [], keepInternal: false))
        // Voice / Photo / Video, each mode (Evil = Normal ids).
        for (pack, slotDef, why) in [(ModelPack.voice, cell.voice, cell.voiceReason), (.photo, cell.photo, cell.photoReason), (.video, cell.video, cell.videoReason)]
        where enabledPacks.contains(pack) {
            for mode in ModelMode.allCases where modes.contains(mode) {
                let ids = mode == .normal ? slotDef?.normal : slotDef?.evil
                var s = simpleSlot(pack: pack, mode: mode, role: pack.rawValue, ids: ids ?? [], reason: why,
                                   mustStay: pack == .voice ? 0 : (cell.embed.flatMap { catalog.models[$0] }.map(FitRule.resident) ?? 0), profile: profile)
                if let o = overrides.first(where: { $0.pack == pack && $0.mode == mode }) {
                    if loadable(o.modelID), let m = catalog.models[o.modelID], allowOverBudget || profile.fits(residentGB: FitRule.resident(m), mustStayGB: 0) {
                        s.modelID = o.modelID; s.installIDs = closure([o.modelID]); s.notes.append(.overrideUsed)
                    } else { s.notes.append(.overrideIgnored) }
                }
                slots.append(s)
            }
        }
        // M3.T05: other-language STT is a Voice pack role of its own, downloaded on demand (`on_demand: [stt_multi]`).
        if enabledPacks.contains(.voice) {
            slots.append(simpleSlot(pack: .voice, mode: .normal, role: "stt_multi", ids: cell.sttMulti.map { [$0] } ?? [],
                                    reason: cell.sttMultiReason, mustStay: 0, profile: profile))
        }
        return Selection(cellKey: key, speedClass: profile.speedClass, slots: slots)
    }

    // MARK: Chat

    private func chatSlot(mode: ModelMode, pick: CatalogChatPick?, reason: String?, mustStay: Double, profile: HardwareProfile,
                          cell: CatalogCell) -> SelectionSlot {
        var slot = SelectionSlot(pack: .chat, mode: mode, role: "chat", modelID: nil, installIDs: [], ctx: nil, fit: nil,
                                 reason: reason, notes: [], keepInternal: false)
        guard let pick else { return slot }
        // Candidates in order: the cell pick, then its step-down. Evil never falls back to the starter (R-227).
        let chain = [pick.model] + (pick.stepDown.map { [$0] } ?? [])
        var firstFitting: (id: String, ctx: Int, model: CatalogModel)?
        for (i, id) in chain.enumerated() where !(mode == .evil && id == cell.chat.fastFirst) {
            guard loadable(id), let m = catalog.models[id],
                  let ctx = ContextLadder.choose(m, cellDefault: pick.ctx, mustStayGB: mustStay, profile: profile) else { continue }
            if firstFitting == nil { firstFitting = (id, ctx, m) }
            // The speed guard steps the primary down; the last candidate is kept even when slow (better than none).
            if SpeedGuard.passes(m, profile: profile) || i == chain.count - 1 {
                let chosen = SpeedGuard.passes(m, profile: profile) ? (id, ctx, m) : firstFitting!
                return finish(&slot, chosen: chosen, primary: pick.model, cellCtx: pick.ctx, mustStay: mustStay, profile: profile)
            }
        }
        if let f = firstFitting { return finish(&slot, chosen: f, primary: pick.model, cellCtx: pick.ctx, mustStay: mustStay, profile: profile) }
        slot.reason = chain.contains(where: loadable) ? "too_large" : "revoked"
        return slot
    }

    private func finish(_ slot: inout SelectionSlot, chosen: (id: String, ctx: Int, model: CatalogModel), primary: String, cellCtx: Int,
                        mustStay: Double, profile: HardwareProfile) -> SelectionSlot {
        slot.modelID = chosen.id
        slot.installIDs = closure([chosen.id])
        slot.ctx = chosen.ctx
        slot.fit = FitRule.classify(residentGB: FitRule.resident(chosen.model, ctx: chosen.ctx), mustStayGB: mustStay, profile: profile)
        slot.reason = nil
        if chosen.id != primary { slot.notes.append(loadable(primary) ? .steppedDown : .revokedReplaced) }
        if chosen.ctx < min(cellCtx, chosen.model.contextMax ?? cellCtx) { slot.notes.append(.contextLowered) }
        return slot
    }

    private func apply(_ o: ModelOverride, to slot: SelectionSlot, mustStay: Double, profile: HardwareProfile, allowOverBudget: Bool,
                       defaultCtx: Int, evil: Bool, fast: String) -> SelectionSlot {
        var s = slot
        guard loadable(o.modelID), let m = catalog.models[o.modelID], m.role == "chat", !(evil && o.modelID == fast) else {
            s.notes.append(.overrideIgnored); return s
        }
        let ctx = ContextLadder.choose(m, cellDefault: max(defaultCtx, m.contextDefault ?? defaultCtx), mustStayGB: mustStay, profile: profile)
        guard ctx != nil || allowOverBudget else { s.notes.append(.overrideIgnored); return s }
        let useCtx = ctx ?? ContextLadder.rungs[0]
        s.modelID = o.modelID; s.installIDs = closure([o.modelID]); s.ctx = useCtx; s.reason = nil
        s.fit = FitRule.classify(residentGB: FitRule.resident(m, ctx: useCtx), mustStayGB: mustStay, profile: profile)
        s.notes = [.overrideUsed]
        return s
    }

    // MARK: Other packs

    private func simpleSlot(pack: ModelPack, mode: ModelMode, role: String, ids: [String], reason: String?, mustStay: Double,
                            profile: HardwareProfile) -> SelectionSlot {
        let usable = ids.filter(loadable)
        guard let first = usable.first else {
            return SelectionSlot(pack: pack, mode: mode, role: role, modelID: nil, installIDs: [], ctx: nil, fit: nil,
                                 reason: reason ?? (ids.isEmpty ? "unavailable" : "revoked"), notes: [], keepInternal: false)
        }
        let parts = closure([first]).compactMap { catalog.models[$0] }
        let resident = parts.reduce(0) { $0 + FitRule.resident($1) }
        return SelectionSlot(pack: pack, mode: mode, role: role, modelID: first, installIDs: closure(usable), ctx: nil,
                             fit: FitRule.classify(residentGB: resident, mustStayGB: mustStay, profile: profile), reason: nil,
                             notes: usable.first != ids.first ? [.revokedReplaced] : [], keepInternal: false)
    }

    /// `ids` plus every `requires`, transitively, in first-seen order.
    public func closure(_ ids: [String]) -> [String] {
        var out: [String] = [], queue = ids
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard !out.contains(id) else { continue }
            out.append(id)
            queue += catalog.models[id]?.requires ?? []
        }
        return out
    }
}

/// M2.T06 step 7 (blueprint E §E.2.3 step 6, NFR-D3/D4): the size the user is shown = Σ unique sha256 sizes − the
/// files already in the store. Shared blobs (tokenizers, text encoders) count once.
public enum DownloadSize {
    public static func bytes(ids: some Sequence<String>, catalog: ModelCatalog, present: Set<String> = []) -> Int64 {
        var seen: [String: Int64] = [:]
        for id in ids { for f in catalog.models[id]?.files ?? [] { seen[f.sha256] = f.size } }
        return seen.filter { !present.contains($0.key) }.values.reduce(0, +)
    }
}
