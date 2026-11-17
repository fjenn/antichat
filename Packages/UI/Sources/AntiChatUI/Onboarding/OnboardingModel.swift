// M2.T18 step 7 (R-201 AC1–AC3, AC6; S-00…S-02): the onboarding view model. Pure over its inputs — the hardware
// profile (T01), the signed catalog (T04/T05, bundled baseline when offline), the free disk (DiskPreflight) and the
// blobs already in the store — so every number on the cards is unit-testable with the tier fixtures:
//   - eligibility = ModelSelector's slot for the pack (HardwareProfile.fits is the one rule); a dimmed card says why,
//     and never "Needs N GB" on a Mac that has N GB or more;
//   - sizes = InstallQueue.plan(…).totalBytes, i.e. Σ unique sha256 − present (never 0.0 GB); Photo and Video carry
//     the media check share (0.4 GB placeholder until M4 pins that role, model-matrix §4);
//   - minutes at a 50 Mbps assumption until a measured throughput exists ("~");
//   - the disk rule free ≥ total + 10 GB (NFR-D2) gates Continue, as does a missing network path (S-00).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import Foundation
import Observation

@MainActor @Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Sendable { case welcome = 1, capabilities, evil, preparing }

    public struct Card: Identifiable, Equatable, Sendable {
        public var pack: ModelPack
        public var id: ModelPack { pack }
        public var eligible: Bool
        /// Why a card is dimmed (nil when eligible).
        public var dimmedReason: CopyText?
        /// What this pack alone downloads (Σ unique sha256 − present, + the check share for Photo/Video).
        public var bytes: Int64
        public var ticked: Bool
        /// Not in this build yet (ModelPack.shipped): "Coming soon", never ticked, never counted.
        public var comingSoon = false
        public var isDefault: Bool { pack == .chat }
        public var toggleable: Bool { eligible && !isDefault }
    }

    /// The media check share shown with Photo / Video until M4 pins that model (model-matrix §4).
    public static let csamPlaceholderBytes: Int64 = 400_000_000
    /// ETA assumption until a measured throughput exists (S-02 "~").
    public static let assumedBitsPerSecond: Double = 50_000_000

    public var step: Step = .welcome
    public private(set) var profile: HardwareProfile?
    public private(set) var catalog: ModelCatalog?
    public private(set) var selection: Selection?
    public var freeBytes: Int64
    public var online: Bool
    public private(set) var cards: [Card] = []
    /// Measured download throughput (bytes/s) once known; nil = the 50 Mbps assumption.
    public var measuredBytesPerSecond: Double?
    private let present: @Sendable (String) -> Bool
    /// The packs this build ships (ModelPack.shipped; tests widen it to render the later milestones' cards).
    let shipped: Set<ModelPack>

    /// Continue on step 2: the install plan to enqueue now (starter first, E.2.4) — wired by the composition root.
    public var onInstall: (InstallPlan) -> Void = { _ in }
    /// Open chat on step 4 (M2.T20): onboarding is done; the downloads keep running.
    public var onFinish: () -> Void = {}
    /// Step 4 Retry on a failed row (re-runs the setup plan; the coordinator skips what is already in).
    public var onRetry: () -> Void = {}

    // MARK: Step 4 (M2.T20)

    /// `onb.4.search.label`, On by default; writes the `search` network category (T03).
    public var searchOn = true { didSet { if searchOn != oldValue { onSearchChanged(searchOn) } } }
    public var onSearchChanged: (Bool) -> Void = { _ in }
    /// M2.T19: Continue on step 3 with Evil on — record consent (ConsentStore via EvilModeManager) and queue the Evil
    /// variants after every Normal set (E.2.4 step 6).
    public var onEvilAccepted: (EvilPlan) -> Void = { _ in }
    /// M10 visual QA (S-04 Back): step 3 Continue with Evil off after an earlier pass queued it (Back from step 4):
    /// the Evil variants stop downloading and the consent is withdrawn.
    public var onEvilDeclined: () -> Void = {}
    /// Evil was queued by an earlier step-3 Continue (Back from step 4 can undo it).
    public private(set) var evilQueued = false

    // MARK: Step 3 (M2.T19)

    /// `onb.3.toggle`, off by default.
    public var evilOn = false
    /// `onb.3.adult`; the red Continue stays disabled until it is ticked (R-211 AC2).
    public var adultConfirmed = false

    public init(profile: HardwareProfile?, catalog: ModelCatalog?, freeBytes: Int64, online: Bool = true,
                present: @escaping @Sendable (String) -> Bool = { _ in false }, shipped: Set<ModelPack> = ModelPack.shipped) {
        self.freeBytes = freeBytes
        self.online = online
        self.present = present
        self.shipped = shipped.union([.chat])
        update(profile: profile, catalog: catalog)
    }

    /// New hardware / catalog facts (the probe finishes after step 1 is on screen; a catalog refresh).
    public func update(profile: HardwareProfile?, catalog: ModelCatalog?) {
        self.profile = profile
        self.catalog = catalog
        guard let profile, let catalog else {
            selection = nil
            cards = ModelPack.allCases.map {
                Card(pack: $0, eligible: $0 == .chat, dimmedReason: shipped.contains($0) ? nil : Self.comingSoonNote, bytes: 0,
                     ticked: $0 == .chat, comingSoon: !shipped.contains($0))
            }
            return
        }
        let sel = Self.withoutOnDemand(ModelSelector(catalog: catalog).select(profile: profile, enabledPacks: Set(ModelPack.allCases),
                                                                              modes: [.normal, .evil]), catalog: catalog)
        selection = sel
        // Only the user's own ticks survive a refresh: the placeholder cards (before the probe/catalog land) and an
        // earlier ineligible state are not choices (M2.T26 VQ: Voice/Photo stayed unticked by default on T1).
        let previous = userChoice
        cards = ModelPack.allCases.map { pack in
            guard shipped.contains(pack) else {
                return Card(pack: pack, eligible: false, dimmedReason: Self.comingSoonNote, bytes: 0, ticked: false, comingSoon: true)
            }
            let eligible = Self.isEligible(pack, sel, profile: profile, catalog: catalog)
            // Defaults (S-02): Chat always; Voice and Photo ticked when eligible; Video unticked even when eligible.
            let defaultTick = pack == .chat || (eligible && (pack == .voice || pack == .photo))
            let ticked = pack == .chat ? true : (eligible && (previous[pack] ?? defaultTick))
            return Card(pack: pack, eligible: eligible,
                        dimmedReason: eligible ? nil : Self.reason(pack, sel, profile: profile, catalog: catalog),
                        bytes: eligible ? bytes(packs: [pack]) : 0, ticked: ticked)
        }
    }

    /// The dimmed line of a pack this build does not ship yet.
    static let comingSoonNote = CopyText(CopyKey("onb.pack.comingSoon.note"))

    // MARK: Derived

    public var chosenPacks: Set<ModelPack> { Set(cards.filter(\.ticked).map(\.pack)) }

    /// Σ unique sha256 of every chosen pack − present (+ one check share with Photo or Video) (+ Evil when on).
    public var totalBytes: Int64 { bytes(packs: chosenPacks) + (evilOn ? (evilPlan?.extraBytes ?? 0) : 0) }

    /// What Evil adds for the chosen packs (nil before the probe).
    public var evilPlan: EvilPlan? {
        guard let selection, let catalog else { return nil }
        return EvilVariantPlanner.plan(selection: selection, catalog: catalog, packs: chosenPacks, present: present)
    }

    /// `onb.3.cost` "Evil adds {size}".
    public var evilCostLine: CopyText { CopyText(CopyKey("onb.3.cost"), ["size": Self.size(evilPlan?.extraBytes ?? 0)]) }

    /// `onb.3.availability.*` from the catalog per chosen pack; never "this device has less" on a Mac that has more.
    public var evilAvailabilityLine: CopyText {
        guard let plan = evilPlan else { return CopyText(CopyKey("onb.hardware.probing")) }
        if plan.availablePacks.isEmpty { return CopyText(CopyKey("onb.3.availability.none")) }
        if plan.unavailablePacks.isEmpty { return CopyText(CopyKey("onb.3.availability.all")) }
        let names = plan.availablePacks.map { CopyKey("onb.pack.\($0.rawValue).name").string() }
        return CopyText(CopyKey("onb.3.availability.some"), ["packs": ListFormatter.localizedString(byJoining: names)])
    }

    /// Why the red Continue on step 3 is disabled (nil = enabled). With Evil off it always continues.
    public var evilContinueBlocked: CopyText? {
        guard evilOn else { return nil }
        if !adultConfirmed { return CopyText(CopyKey("onb.3.adult")) }
        if evilPlan?.isAvailable != true { return CopyText(CopyKey("onb.3.availability.none")) }
        if case .short(let gb) = disk { return CopyText(CopyKey("onb.diskShort"), ["gb": String(gb)]) }
        return nil
    }

    public var disk: DiskPreflight.Result { DiskPreflight.check(total: totalBytes, free: freeBytes) }

    /// Why Continue on step 2 is disabled (nil = enabled). No network wins: the CTA label itself says so.
    public var continueBlocked: CopyText? {
        if !online { return CopyText(CopyKey("onb.noInternet")) }
        if case .short(let gb) = disk { return CopyText(CopyKey("onb.diskShort"), ["gb": String(gb)]) }
        if selection == nil { return CopyText(CopyKey("onb.hardware.probing")) }
        return nil
    }

    /// `onb.hardware` ("{chip} · {ram} GB memory · {free} GB available"), or `onb.hardware.probing`.
    public var hardwareLine: CopyText {
        guard let p = profile else { return CopyText(CopyKey("onb.hardware.probing")) }
        return CopyText(CopyKey("onb.hardware"), ["chip": p.chip, "ram": String(p.ramGB),
                                                  "free": String(Int((Double(freeBytes) / 1e9).rounded(.down)))])
    }

    public func sizeLine(_ card: Card) -> CopyText {
        guard card.bytes > 0 else { return CopyText(CopyKey("onb.pack.installed")) }
        return CopyText(CopyKey("onb.pack.size"), ["size": Self.size(card.bytes), "minutes": String(minutes(card.bytes))])
    }

    public var totalLine: CopyText {
        CopyText(CopyKey("onb.2.total"), ["size": Self.size(totalBytes), "minutes": String(minutes(totalBytes))])
    }

    // MARK: Actions

    /// Relaunch at step 4: the saved choice unticks what was not chosen.
    func untick(_ pack: ModelPack) {
        guard let i = cards.firstIndex(where: { $0.pack == pack }), cards[i].toggleable else { return }
        cards[i].ticked = false
        userChoice[pack] = false
    }

    /// M2.T20 relaunch mid-onboarding: the saved step-2/3 choice, resumed at step 4. SetupLaunch.resume queues Evil
    /// directly (no step-3 Continue), so it counts as queued here too: Back, Evil off, Continue must still withdraw it.
    func resume(packs: Set<ModelPack>, evil: Bool) {
        for pack in ModelPack.allCases where pack != .chat && !packs.contains(pack) { untick(pack) }
        evilOn = evil
        evilQueued = evil
        step = .preparing
    }

    public func toggle(_ pack: ModelPack) {
        guard let i = cards.firstIndex(where: { $0.pack == pack }), cards[i].toggleable else { return }
        cards[i].ticked.toggle()
        userChoice[pack] = cards[i].ticked
    }

    /// The packs the user ticked or unticked themselves (kept across hardware/catalog refreshes).
    private var userChoice: [ModelPack: Bool] = [:]

    public func next() {
        switch step {
        case .welcome: step = .capabilities
        case .capabilities:
            guard continueBlocked == nil else { return }
            startInstall()
            step = .evil
        case .evil:
            guard evilContinueBlocked == nil else { return }
            if evilOn, let plan = evilPlan {
                onEvilAccepted(plan)
                evilQueued = true
            } else {
                // Off at step 3 means off, also when an earlier install left Evil enabled (2026-11-15: a reinstall
                // showed an "Evil Mode · Waiting" row after Continue with the switch off).
                onEvilDeclined()
                evilQueued = false
            }
            step = .preparing
        case .preparing: onFinish()
        }
    }

    public func back() {
        // M10 visual QA (S-04, onboarding_page4): step 4 has Back too. The downloads keep running; a changed choice is
        // applied by the next Continue (step 2 re-plans and drops what was unticked, step 3 adds or drops Evil).
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    /// NFR-M5: `onboardingContinue` starts the clock; the plan goes to the queue at once (starter first).
    private func startInstall() {
        guard let selection, let catalog else { return }
        Signposts.event(.onboardingContinue, on: Signposts.ui)
        onInstall(InstallQueue.plan(selection: selection, catalog: catalog, packs: chosenPacks, modes: [.normal], present: present))
    }

    // MARK: Rules

    func bytes(packs: Set<ModelPack>) -> Int64 {
        guard let selection, let catalog, !packs.isEmpty else { return 0 }
        let plan = InstallQueue.plan(selection: selection, catalog: catalog, packs: packs, modes: [.normal], present: present)
        let checkPending = selection.slot(.photo, .normal, role: "csam_check")?.modelID == nil
        let share = checkPending && (packs.contains(.photo) || packs.contains(.video)) ? Self.csamPlaceholderBytes : 0
        return plan.totalBytes + share
    }

    /// On-demand models (e.g. the reranker) are not part of the default download (catalog `on_demand`, T06 sizes);
    /// onboarding, its relaunch resume and Capabilities all plan through this.
    nonisolated static func withoutOnDemand(_ selection: Selection, catalog: ModelCatalog) -> Selection {
        let onDemand = Set(catalog.onDemand)
        var sel = selection
        sel.slots = sel.slots.map { s in
            var s = s
            if let id = s.modelID, onDemand.contains(id) { s.modelID = nil; s.installIDs = [] }
            return s
        }
        return sel
    }

    static func role(_ pack: ModelPack) -> String { pack == .chat ? "chat" : pack.rawValue }

    static func isEligible(_ pack: ModelPack, _ sel: Selection) -> Bool {
        sel.slot(pack, .normal, role: role(pack))?.modelID != nil
    }

    /// M5.T08 (R-046 AC1): Video follows `VideoEligibility` (tier, speed class, the speed table, B) on every surface;
    /// the other packs follow the selector.
    static func isEligible(_ pack: ModelPack, _ sel: Selection, profile: HardwareProfile, catalog: ModelCatalog?) -> Bool {
        guard pack == .video else { return isEligible(pack, sel) }
        return VideoEligibility.evaluate(profile: profile, selection: sel, catalog: catalog).isEligible
    }

    /// The dimmed line (hardware-tiers §4.5): RAM floors from the catalog reason (`needs_ram_<N>`), never a floor at
    /// or below this Mac's memory; speed-class refusals say the chip is too slow.
    static func reason(_ pack: ModelPack, _ sel: Selection, profile: HardwareProfile, catalog: ModelCatalog? = nil) -> CopyText {
        if pack == .video, let r = VideoEligibility.evaluate(profile: profile, selection: sel, catalog: catalog).reason {
            return r.copyText
        }
        let why = sel.slot(pack, .normal, role: role(pack))?.reason ?? ""
        if why.hasPrefix("needs_ram_"), let n = Int(why.dropFirst("needs_ram_".count)) {
            if n > profile.ramGB {
                if pack == .photo, profile.tier == .T0 { return CopyText(CopyKey("onb.pack.dimmed.photo.t0")) }
                return CopyText(CopyKey("onb.pack.dimmed.ram"), ["gb": String(n)])
            }
        }
        if why.contains("slow") || why.contains("speed") || why.contains("chip") {
            return CopyText(CopyKey("onb.pack.dimmed.chip"))
        }
        // too_large / an unparseable floor: the next standard memory size above this Mac's (truthful by construction).
        let next = [16, 24, 32, 48, 64, 96, 128, 192, 256, 512].first { $0 > profile.ramGB } ?? profile.ramGB * 2
        return CopyText(CopyKey("onb.pack.dimmed.ram"), ["gb": String(next)])
    }

    /// Copy-deck rule: one decimal under 10 GB, none above; never "0.0 GB".
    public static func size(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 10 { return "\(Int(gb.rounded())) GB" }
        return String(format: "%.1f GB", max(0.1, (gb * 10).rounded() / 10))
    }

    func minutes(_ bytes: Int64) -> Int {
        let bps = measuredBytesPerSecond.map { $0 * 8 } ?? Self.assumedBitsPerSecond
        return max(1, Int((Double(bytes) * 8 / bps / 60).rounded(.up)))
    }
}
