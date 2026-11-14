// M2.T09 steps 6–7 (R-204 AC7, NFR-D5, NFR-SEC7; blueprint E §E.2.4): what to download, in which order, each file once.
// Order: `chat_fast` alone until verified → tier `chat` + `embed` (+ `rerank`) → Voice (VAD → STT → TTS, catalog
// order) → Photo + `csam_check` → Video → Evil variants (same pack order). Files are deduplicated by sha256 across
// packs and modes, and a blob already in the store (or already queued — the coordinator's own dedup) is never
// fetched again. Nothing is enqueued unless the catalog allows new installs (`CatalogStore.mayInstallNew`: verified,
// unexpired, no bad signature — NFR-SEC7) and the disk rule passes (`DiskPreflight`, NFR-D2).
import Foundation

public struct InstallPlan: Sendable, Equatable {
    public enum StageKind: String, Sendable, CaseIterable { case chatFast, chatEmbed, voice, photo, video, evil }

    public struct Item: Sendable, Equatable {
        public var modelID: String
        public var pack: ModelPack
        public var mode: ModelMode
        public var role: String
        /// This item's files not already planned by an earlier item and not in the store.
        public var requests: [DownloadRequest]
    }

    public struct Stage: Sendable, Equatable {
        public var kind: StageKind
        public var items: [Item]
        public var requests: [DownloadRequest] { items.flatMap(\.requests) }
    }

    public var stages: [Stage]
    /// Every request in queue order (priority = position).
    public var requests: [DownloadRequest] { stages.flatMap(\.requests) }
    /// Σ unique sha256 sizes not in the store (the size the user is shown).
    public var totalBytes: Int64 { requests.reduce(0) { $0 + $1.size } }
    public var isEmpty: Bool { requests.isEmpty }
}

public enum InstallQueue {
    /// The progress group of an item: its pack, except the Evil chat variant (`evil`, the ModeSwitch's "Evil ready in …").
    static func group(_ pack: ModelPack, _ mode: ModelMode) -> String { mode == .evil && pack == .chat ? "evil" : pack.rawValue }

    public static func plan(selection: Selection, catalog: ModelCatalog, packs: Set<ModelPack>, modes: Set<ModelMode>,
                            present: (String) -> Bool = { _ in false }) -> InstallPlan {
        var order: [(InstallPlan.StageKind, [SelectionSlot])] = []
        func slots(_ pack: ModelPack, _ mode: ModelMode, roles: [String]) -> [SelectionSlot] {
            guard packs.contains(pack), modes.contains(mode) else { return [] }
            return roles.compactMap { r in selection.slots.first { $0.pack == pack && $0.mode == mode && $0.role == r } }
        }
        order.append((.chatFast, slots(.chat, .normal, roles: ["chat_fast"])))
        order.append((.chatEmbed, slots(.chat, .normal, roles: ["chat", "embed", "rerank"])))
        order.append((.voice, slots(.voice, .normal, roles: ["voice"])))
        order.append((.photo, slots(.photo, .normal, roles: ["photo", "csam_check"])))
        // The ChildSafetyCheck detectors (D-006) come with Video too, not only with Photo (deduplicated by `seen`).
        let csamForVideo = packs.contains(.video) && modes.contains(.normal)
            ? selection.slots.filter { $0.role == "csam_check" } : []
        order.append((.video, slots(.video, .normal, roles: ["video"]) + csamForVideo))
        order.append((.evil, slots(.chat, .evil, roles: ["chat"]) + slots(.voice, .evil, roles: ["voice"])
                      + slots(.photo, .evil, roles: ["photo"]) + slots(.video, .evil, roles: ["video"])))
        var seen = Set<String>()
        var priority = 0
        var stages: [InstallPlan.Stage] = []
        for (kind, ss) in order {
            var items: [InstallPlan.Item] = []
            for s in ss where s.modelID != nil {
                for id in ordered(s.installIDs, catalog: catalog) {
                    guard let m = catalog.models[id] else { continue }
                    var reqs: [DownloadRequest] = []
                    for f in m.files where !seen.contains(f.sha256) {
                        seen.insert(f.sha256)
                        if present(f.sha256) { continue }
                        reqs.append(DownloadRequest(file: f, model: m, pack: group(s.pack, s.mode), priority: priority))
                        priority += 1
                    }
                    items.append(InstallPlan.Item(modelID: id, pack: s.pack, mode: s.mode, role: s.role, requests: reqs))
                }
            }
            if !items.isEmpty { stages.append(InstallPlan.Stage(kind: kind, items: items)) }
        }
        return InstallPlan(stages: stages)
    }

    /// Within a slot: Voice goes VAD → STT → TTS (E.2.4) by catalog role; other packs keep the catalog order.
    static func ordered(_ ids: [String], catalog: ModelCatalog) -> [String] {
        let rank = ["vad": 0, "stt": 1, "tts": 2]
        return ids.enumerated().sorted { a, b in
            let ra = rank[catalog.models[a.element]?.role ?? ""] ?? 1, rb = rank[catalog.models[b.element]?.role ?? ""] ?? 1
            return (ra, a.offset) < (rb, b.offset)
        }.map(\.element)
    }

    public enum Outcome: Sendable, Equatable {
        case enqueued(jobs: Int)
        /// The catalog may not install anything new (bad signature / expired / none): zero jobs (NFR-SEC7).
        case catalogRefused
        case diskShort(gbNeeded: Int)
        case nothingToDo
    }

    /// Enqueues `plan`: the `chat_fast` stage alone, waiting until it is verified, then the rest in order.
    /// `free` = free bytes on the Models volume (the one disk rule is checked here, for every entry point).
    @discardableResult
    public static func run(_ plan: InstallPlan, coordinator: DownloadCoordinator, mayInstallNew: Bool, free: Int64,
                           onStarted: (@Sendable (Outcome) -> Void)? = nil) async -> Outcome {
        guard mayInstallNew else { onStarted?(.catalogRefused); return .catalogRefused }
        if case .short(let gb) = DiskPreflight.check(total: plan.totalBytes, free: free) {
            onStarted?(.diskShort(gbNeeded: gb)); return .diskShort(gbNeeded: gb)
        }
        guard !plan.isEmpty else { onStarted?(.nothingToDo); return .nothingToDo }
        onStarted?(.enqueued(jobs: plan.requests.count))
        var count = 0
        var rest = plan.stages[...]
        if let first = rest.first, first.kind == .chatFast {
            rest = rest.dropFirst()
            var ids: [String] = []
            for r in first.requests { ids.append(await coordinator.enqueue(r).id); count += 1 }
            // A user pause of the starter must not hold the rest of the setup forever (M2 review #7): once it is
            // verified, failed or paused, the remaining stages are enqueued (they queue behind it by priority).
            for id in ids { _ = await coordinator.wait(id, orPaused: true) }
        }
        for s in rest { for r in s.requests { await coordinator.enqueue(r); count += 1 } }
        return .enqueued(jobs: count)
    }
}
