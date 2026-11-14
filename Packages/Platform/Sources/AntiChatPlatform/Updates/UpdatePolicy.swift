// M2.T11 steps 1–2 (R-294 AC1–AC4, R-220 AC2; blueprint E §E.2.6 "updates"; P-platform-04): what a verified catalog
// refresh means for the installed slots, and whether an update downloads silently or asks.
//   candidate: an installed slot whose model a newer entry `supersedes` (or whose model is `disable`-revoked and has a
//              replacement) → UpdateCandidate {slot, from, to, extraBytes}; extra = Σ unique sha256 of `to` not yet in
//              the store (shared tokenizer blobs cost nothing).
//   auto     ⇔ "Update models automatically" on, the path is neither expensive nor constrained (Low Data Mode),
//              extra ≤ 2 GB and NFR-D2 (free ≥ extra + 10 GB) passes; otherwise the Capabilities offer row asks
//              ([Update] [Later]). On an expensive / constrained path nothing downloads, asked or not.
//   A revocation (`disable`) is not optional: it switches even with auto-update off (disk and path rules still apply).
import AntiChatNetwork
import AntiChatStorage
import Foundation

public struct UpdateCandidate: Sendable, Equatable, Hashable {
    public enum Reason: String, Sendable { case supersedes, revoked }
    /// `model_install.slot` (`<pack>/<mode>/<role>`).
    public var slot: String
    public var from: String
    public var to: String
    public var extraBytes: Int64
    public var reason: Reason

    public init(slot: String, from: String, to: String, extraBytes: Int64, reason: Reason) {
        self.slot = slot; self.from = from; self.to = to; self.extraBytes = extraBytes; self.reason = reason
    }

    /// The pack part of the slot ("chat/normal/chat_fast" → chat).
    public var pack: ModelPack { ModelPack(rawValue: String(slot.prefix { $0 != "/" })) ?? .chat }
}

public enum UpdatePolicy {
    public static let autoLimitBytes: Int64 = 2_000_000_000

    public enum Decision: Sendable, Equatable {
        case auto
        /// The offer row: "A better {pack} model is available ({size}). Update now?"
        case ask
        /// No download now (expensive / constrained path); re-evaluated on the next refresh or path change.
        case holdNetwork
        /// NFR-D2 fails: "Needs {gb} GB more free space."
        case diskShort(gbNeeded: Int)
    }

    public static func decide(_ c: UpdateCandidate, autoUpdate: Bool, path: PathStatus.State, free: Int64) -> Decision {
        if path == .expensive || path == .constrained || path == .none { return .holdNetwork }
        if case .short(let gb) = DiskPreflight.check(total: c.extraBytes, free: free) { return .diskShort(gbNeeded: gb) }
        if c.reason == .revoked { return .auto }
        return autoUpdate && c.extraBytes <= autoLimitBytes ? .auto : .ask
    }

    /// Step 1: diff the installed slots against `catalog`. `replacement(slot)` names the model a revoked slot switches
    /// to when no entry supersedes it (the selector's pick for that slot, T06).
    public static func candidates(installed: [ModelInstallRecord], catalog: ModelCatalog, present: Set<String>,
                                  rejected: Set<String> = [], replacement: (String) -> String? = { _ in nil }) -> [UpdateCandidate] {
        installed.compactMap { row -> UpdateCandidate? in
            let from = row.catalogEntryID
            let usable: (String) -> Bool = { id in
                guard let m = catalog.models[id], !rejected.contains(id) else { return false }
                return catalog.revocation(for: id)?.action != .disable && CatalogStore.isCompatible(m)
            }
            let superseder = catalog.models.values.filter { ($0.supersedes ?? []).contains(from) && usable($0.id) }.map(\.id).sorted().first
            let revoked = catalog.revocation(for: from)?.action == .disable
            guard let to = superseder ?? (revoked ? replacement(row.slot).flatMap { usable($0) && $0 != from ? $0 : nil } : nil) else { return nil }
            return UpdateCandidate(slot: row.slot, from: from, to: to, extraBytes: DownloadSize.bytes(ids: [to], catalog: catalog, present: present),
                                   reason: superseder == nil ? .revoked : .supersedes)
        }
    }
}
