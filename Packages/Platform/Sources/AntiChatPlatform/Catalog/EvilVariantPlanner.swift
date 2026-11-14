// M2.T19 (R-227, R-201 AC4; blueprint E §E.2.4 step 6; model-matrix §9.3): what turning Evil on costs and where it is
// available — shared by onboarding step 3 and the Settings enable path (one code path, DoD).
//   extraBytes   = Σ unique sha256 of the Evil variants of the chosen packs − files already in the store − files the
//                  Normal set already brings (shared tokenizers count once) — i.e. plan(normal+evil) − plan(normal);
//   available    = chosen packs whose Evil slot has a model on this Mac (Photo/Video Evil = the Normal ids, Q-009 a,
//                  so they are available wherever Normal is and add 0 bytes);
//   unavailable  = chosen packs without one (`evil.notAvailablePack`; never a weaker stand-in, R-227 AC3).
// EvilReadiness is the state the ModeSwitch and the step-4 Evil row show (T20/T21).
import Foundation

public struct EvilPlan: Sendable, Equatable {
    public var extraBytes: Int64
    public var availablePacks: [ModelPack]
    public var unavailablePacks: [ModelPack]
    /// The download plan of the Evil variants alone (stage `.evil`), queued after every Normal set.
    public var requests: [DownloadRequest]
    /// M2.T20: the Evil items (model id, pack, role) the requests belong to — what the setup installer materialises.
    public var items: [InstallPlan.Item] = []
    public var isAvailable: Bool { !availablePacks.isEmpty }
}

public enum EvilVariantPlanner {
    /// `selection` must be selected with modes [.normal, .evil] (ModelSelector), on-demand models stripped.
    public static func plan(selection: Selection, catalog: ModelCatalog, packs: Set<ModelPack>,
                            present: (String) -> Bool = { _ in false }) -> EvilPlan {
        let normal = InstallQueue.plan(selection: selection, catalog: catalog, packs: packs, modes: [.normal], present: present)
        let both = InstallQueue.plan(selection: selection, catalog: catalog, packs: packs, modes: [.normal, .evil], present: present)
        var available: [ModelPack] = [], unavailable: [ModelPack] = []
        for pack in ModelPack.allCases where packs.contains(pack) {
            let role = pack == .chat ? "chat" : pack.rawValue
            // Only packs this Mac runs in Normal are listed at all (a dimmed pack was never chosen).
            guard selection.slot(pack, .normal, role: role)?.modelID != nil else { continue }
            if selection.slot(pack, .evil, role: role)?.modelID != nil { available.append(pack) } else { unavailable.append(pack) }
        }
        let evilStages = both.stages.filter { $0.kind == .evil }
        return EvilPlan(extraBytes: max(0, both.totalBytes - normal.totalBytes), availablePacks: available,
                        unavailablePacks: unavailable, requests: evilStages.flatMap(\.requests),
                        items: evilStages.flatMap(\.items))
    }

    /// Model ids used only in Evil mode anywhere in the catalog (what "Remove Evil models" may delete; shared Normal
    /// ids — Photo/Video under Q-009 a, the starter — are never in it).
    public static func evilOnlyIDs(catalog: ModelCatalog) -> Set<String> {
        var evil = Set<String>(), normal = Set<String>()
        for cells in catalog.assignments.values {
            for cell in cells.values {
                if let p = cell.chat.evil { evil.insert(p.model); p.stepDown.map { _ = evil.insert($0) } }
                if let p = cell.chat.normal { normal.insert(p.model); p.stepDown.map { _ = normal.insert($0) } }
                normal.insert(cell.chat.fastFirst)
                for s in [cell.voice, cell.photo, cell.video].compactMap({ $0 }) {
                    evil.formUnion(s.evil)
                    normal.formUnion(s.normal)
                }
                [cell.embed, cell.rerank, cell.sttMulti, cell.csamCheck, cell.citeCheck].compactMap { $0 }.forEach { normal.insert($0) }
            }
        }
        return evil.subtracting(normal)
    }
}

/// M2.T19 step 6: what the ModeSwitch (`evil.downloading` "Evil ready in ~{minutes} min", disabled) and the step-4
/// Evil row show. Never a weaker stand-in: `unavailable` stays unavailable (R-227 AC3).
public enum EvilReadiness: Sendable, Equatable {
    case notEnabled
    /// nil minutes = no throughput sample yet (queued behind the other packs).
    case downloading(etaMinutes: Int?)
    case verifying
    case ready
    case unavailable(reason: String)

    /// Pure: `remainingBytes` of the Evil variants still to fetch, `bytesPerSecond` the measured rate (nil = none yet).
    public static func state(enabled: Bool, plan: EvilPlan, remainingBytes: Int64, verifying: Bool,
                             bytesPerSecond: Double?) -> EvilReadiness {
        guard enabled else { return .notEnabled }
        guard plan.isAvailable else { return .unavailable(reason: "evil_not_available") }
        if remainingBytes > 0 {
            return .downloading(etaMinutes: bytesPerSecond.flatMap { $0 > 0 ? max(1, Int((Double(remainingBytes) / $0 / 60).rounded(.up))) : nil })
        }
        return verifying ? .verifying : .ready
    }

    /// The copy key the ModeSwitch shows (nil = no line).
    public var copyKey: String? {
        switch self {
        case .downloading(let m): m == nil ? "evil.downloading.queued" : "evil.downloading"
        case .ready: "evil.ready"
        case .unavailable: "onb.3.availability.none"
        case .notEnabled, .verifying: nil
        }
    }
}
