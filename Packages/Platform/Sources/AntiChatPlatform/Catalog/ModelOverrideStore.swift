// M2.T07 (R-222 AC2–AC4; blueprint E §E.2.3 step 5): Settings › Capabilities › Advanced's model choice per pack × mode.
// Overrides are `model_override {pack, mode, model_id}` rows: they name a catalog id only, so they survive app
// updates (the table is not touched by migrations) and catalog updates (re-resolved against each new catalog by the
// selector). A row whose id is unknown or `disable`-revoked in the current catalog falls back to the recommended
// model and reports a `model.revoked` notice once per catalog. "Reset to recommended" deletes every row of a pack.
// The picker lists the catalog models of the slot's role with their FitRule class (Fits / Tight / Too large);
// Too large stays disabled unless "Allow loads above the memory budget" is on (NFR-R5).
import AntiChatStorage
import Foundation
import GRDB

public struct ModelOverrideStore: Sendable {
    public let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func all() -> [ModelOverride] { ModelOverride.load((try? ModelOverrideRecord.all(database)) ?? []) }

    public func override(_ pack: ModelPack, _ mode: ModelMode) -> ModelOverride? {
        all().first { $0.pack == pack && $0.mode == mode }
    }

    /// Sets (or, with nil, clears) the model for one pack × mode.
    public func set(_ pack: ModelPack, _ mode: ModelMode, modelID: String?) throws {
        try database.write { db in
            if let modelID {
                try ModelOverrideRecord(pack: pack.rawValue, mode: mode.rawValue, modelID: modelID).save(db)
            } else {
                _ = try ModelOverrideRecord.filter(Column("pack") == pack.rawValue && Column("mode") == mode.rawValue).deleteAll(db)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// "Reset to recommended" (`set.cap.reset`): every override of `pack`, both modes.
    public func reset(_ pack: ModelPack) throws {
        try database.write { db in _ = try ModelOverrideRecord.filter(Column("pack") == pack.rawValue).deleteAll(db) }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    public static let didChange = Notification.Name("AntiChatModelOverridesDidChange")

    // MARK: Resolution against a catalog

    public struct Resolved: Sendable, Equatable {
        /// The overrides the selector should apply (unknown / revoked ones removed).
        public var overrides: [ModelOverride]
        /// Overrides that fell back to the recommended model (`model.revoked`): the stored row stays, so a later
        /// catalog that un-revokes the id brings it back.
        public var fellBack: [ModelOverride]
    }

    /// E.2.3 step 5: an override whose model is unknown or `disable`-revoked is ignored (recommended instead) and
    /// reported. `isLoadable` defaults to the catalog's own rule (CatalogStore.isLoadable semantics).
    public static func resolve(_ overrides: [ModelOverride], catalog: ModelCatalog,
                               isLoadable: ((String) -> Bool)? = nil) -> Resolved {
        let ok: (String) -> Bool = isLoadable ?? { id in
            guard let m = catalog.models[id], catalog.revocation(for: id)?.action != .disable else { return false }
            return CatalogStore.isCompatible(m)
        }
        var r = Resolved(overrides: [], fellBack: [])
        for o in overrides { if ok(o.modelID) { r.overrides.append(o) } else { r.fellBack.append(o) } }
        return r
    }

    // MARK: Picker

    public struct Option: Sendable, Equatable, Identifiable {
        public var id: String { modelID }
        public var modelID: String
        public var quant: String?
        public var ctx: Int?
        public var fit: FitClass
        public var recommended: Bool
        /// Too large and "Allow loads above the memory budget" is off.
        public var disabled: Bool

        public init(modelID: String, quant: String?, ctx: Int?, fit: FitClass, recommended: Bool, disabled: Bool) {
            self.modelID = modelID; self.quant = quant; self.ctx = ctx; self.fit = fit; self.recommended = recommended; self.disabled = disabled
        }
    }

    /// Catalog models a pack × mode can use, in order: recommended first, then by resident size. Chat lists the
    /// `chat` role (Evil never offers the starter `chat_fast`, R-227); Voice/Photo/Video list the models of the
    /// cell's pack list for that mode (their first entry is the swappable one).
    public static func options(pack: ModelPack, mode: ModelMode, selection: Selection, catalog: ModelCatalog,
                               profile: HardwareProfile, allowOverBudget: Bool) -> [Option] {
        let slot = pack == .chat ? selection.slot(.chat, mode, role: "chat") : selection.slot(pack, mode)
        let recommended = slot?.modelID
        let fast = selection.chatFast?.modelID
        let loadable: (CatalogModel) -> Bool = { m in catalog.revocation(for: m.id)?.action != .disable && CatalogStore.isCompatible(m) }
        let candidates: [CatalogModel]
        let mustStay: Double
        if pack == .chat {
            let cell = catalog.cell(tier: profile.tier, ramGB: profile.ramGB, speedClass: profile.speedClass)?.cell
            mustStay = cell.map { ResidencyTable.mustStayGB(cell: $0, catalog: catalog, voiceEnabled: false) } ?? 0
            let evilFamily = mode == .evil
            candidates = catalog.models.values.filter { m in
                m.role == "chat" && loadable(m) && !(evilFamily && m.id == fast)
                    // Evil lists the Evil (abliterated) entries, Normal the Normal ones (both are role "chat").
                    && (m.id.hasPrefix("evil-") == evilFamily || m.id == recommended)
            }
        } else {
            // Same role and engine as the recommended entry; components (`requires` of another entry) are not choices.
            mustStay = 0
            let parts = Set(catalog.models.values.flatMap { $0.requires ?? [] })
            let rec = recommended.flatMap { catalog.models[$0] }
            candidates = catalog.models.values.filter { m in
                loadable(m) && !parts.contains(m.id) && (m.id == recommended || (rec.map { m.role == $0.role && m.engine == $0.engine } ?? false))
            }
        }
        let closureGB: (CatalogModel) -> Double = { m in
            ModelSelector(catalog: catalog).closure([m.id]).compactMap { catalog.models[$0] }.reduce(0) { $0 + FitRule.resident($1) }
        }
        let opts = candidates.map { m -> (Option, Double) in
            let ctx = pack == .chat ? (m.id == recommended ? slot?.ctx : nil) ?? ContextLadder.choose(m, cellDefault: m.contextDefault ?? 8192,
                                                                                                      mustStayGB: mustStay, profile: profile) : nil
            let resident = pack == .chat ? FitRule.resident(m, ctx: ctx ?? ContextLadder.rungs[0]) : closureGB(m)
            let fit = FitRule.classify(residentGB: resident, mustStayGB: mustStay, profile: profile)
            return (Option(modelID: m.id, quant: m.quant, ctx: ctx ?? (pack == .chat ? ContextLadder.rungs[0] : nil), fit: fit,
                           recommended: m.id == recommended, disabled: fit == .tooLarge && !allowOverBudget), resident)
        }
        return opts.sorted { a, b in
            if a.0.recommended != b.0.recommended { return a.0.recommended }
            return (a.1, a.0.modelID) < (b.1, b.0.modelID)
        }.map(\.0)
    }
}
