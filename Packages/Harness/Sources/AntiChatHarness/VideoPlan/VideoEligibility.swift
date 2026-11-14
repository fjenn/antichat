// M5.T08 step 1 (R-046 AC1, R-040 AC4; G-046; hardware-tiers §4.4–§4.5; P-media-12, tier validation after
// osaurus@2922745 `LocalVideoRequestPolicy`): can this Mac make video, and which presets.
//   T0–T1 (or a catalog `needs_ram_<N>` above this Mac's memory) → dimmed "Needs {gb} GB memory" (gb = 24);
//   catalog speed refusal, or no speed-table row for the class → dimmed "Too slow on this Mac's chip";
//   T2-S1 → eligible "Shown-lite": 480p short presets only;
//   otherwise every preset the class has coefficients for whose memory verdict is not `exceeds`;
//   runtime not installed → still eligible (`needsRuntime`): the pack's install card, never dimmed.
// The reason is shown on the onboarding Video card, the + menu's Create video row (disabled, tooltip) and the
// Settings → Capabilities Video row; Video is never hidden. Harness never sees Platform: AntiChatUI maps the
// HardwareProfile + catalog Selection into `Input` (VideoEligibility+Profile.swift).
import Foundation

public enum VideoEligibility {
    /// hardware-tiers §4.5: video needs a 24 GB Mac (T2).
    public static let minimumRAMGB = 24
    /// The presets Shown-lite keeps (T2-S1): 480p short clips.
    public static let liteSuffix = "480p-short"

    public struct Input: Sendable, Equatable {
        /// "T0" … "T4".
        public var tier: String
        /// "S1" … "S4".
        public var speedClass: String
        public var ramGB: Int
        /// The memory budget B (GB).
        public var budgetGB: Double
        /// The catalog's video model for this tier (nil = the catalog refuses video here, see `catalogReason`).
        public var videoModelID: String?
        /// The catalog's refusal (`needs_ram_24`, …) when `videoModelID` is nil.
        public var catalogReason: String?
        /// What must stay resident during a job (T3+: the chat model; T2 unloads chat first → 0).
        public var residentGB: Double
        public var runtimeInstalled: Bool

        public init(tier: String, speedClass: String, ramGB: Int, budgetGB: Double, videoModelID: String?,
                    catalogReason: String? = nil, residentGB: Double = 0, runtimeInstalled: Bool = true) {
            self.tier = tier; self.speedClass = speedClass; self.ramGB = ramGB; self.budgetGB = budgetGB
            self.videoModelID = videoModelID; self.catalogReason = catalogReason; self.residentGB = residentGB
            self.runtimeInstalled = runtimeInstalled
        }
    }

    public enum Reason: Sendable, Equatable, Hashable {
        /// `onb.pack.dimmed.ram` "Needs {gb} GB memory".
        case needsMemory(gb: Int)
        /// `onb.pack.dimmed.chip` "Too slow on this Mac's chip".
        case chipTooSlow

        public var copyKey: String {
            switch self {
            case .needsMemory: "onb.pack.dimmed.ram"
            case .chipTooSlow: "onb.pack.dimmed.chip"
            }
        }

        public var copyArgs: [String: String] {
            switch self {
            case .needsMemory(let gb): ["gb": String(gb)]
            case .chipTooSlow: [:]
            }
        }
    }

    public struct Offer: Sendable, Equatable {
        /// Preset keys this Mac may run (speed-table order).
        public var presets: [String]
        /// T2-S1 "Shown-lite" (480p short only).
        public var lite: Bool
        /// The video runtime is not installed yet: show its install card (not a dimmed state).
        public var needsRuntime: Bool
    }

    public enum Result: Sendable, Equatable {
        case eligible(Offer)
        case dimmed(Reason)

        public var isEligible: Bool { if case .eligible = self { true } else { false } }
        public var reason: Reason? { if case .dimmed(let r) = self { r } else { nil } }
    }

    public static func evaluate(_ i: Input, table: VideoSpeedTable = .bundled) -> Result {
        let lowTier = i.tier == "T0" || i.tier == "T1"
        let floor = catalogRAMFloor(i.catalogReason)
        if let n = floor, n > i.ramGB { return .dimmed(.needsMemory(gb: n)) }
        if lowTier || i.ramGB < minimumRAMGB { return .dimmed(.needsMemory(gb: max(minimumRAMGB, floor ?? 0))) }
        if i.videoModelID == nil {
            if let why = i.catalogReason, why.contains("slow") || why.contains("speed") || why.contains("chip") {
                return .dimmed(.chipTooSlow)
            }
            // A refusal that names no floor this Mac misses: the next standard size up (truthful by construction).
            return .dimmed(.needsMemory(gb: nextRAM(i.ramGB)))
        }
        let lite = i.tier == "T2" && i.speedClass == "S1"
        var presets = table.presets(speedClass: i.speedClass).filter { p in
            guard let r = table.row(speedClass: i.speedClass, preset: p.key) else { return false }
            return VideoEstimator.verdict(peakGB: r.peakGB, residentGB: i.residentGB, budgetGB: i.budgetGB) != .exceeds
        }.map(\.key)
        if lite { presets = presets.filter { $0.hasSuffix(liteSuffix) } }
        guard !presets.isEmpty else {
            // No coefficients for this class (or nothing fits B): the chip cannot run the smallest clip in time/memory.
            return table.presets(speedClass: i.speedClass).isEmpty ? .dimmed(.chipTooSlow) : .dimmed(.needsMemory(gb: nextRAM(i.ramGB)))
        }
        return .eligible(Offer(presets: presets, lite: lite, needsRuntime: !i.runtimeInstalled))
    }

    /// `needs_ram_<N>` → N.
    static func catalogRAMFloor(_ reason: String?) -> Int? {
        guard let r = reason, r.hasPrefix("needs_ram_") else { return nil }
        return Int(r.dropFirst("needs_ram_".count))
    }

    static func nextRAM(_ ram: Int) -> Int { [32, 48, 64, 96, 128, 192, 256, 512].first { $0 > ram } ?? ram * 2 }
}
