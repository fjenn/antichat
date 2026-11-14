// M2.T01 (R-200, G-049): the Mac's hardware profile (blueprint E §E.2.1 step 4 output). Feeds the selector (T06),
// onboarding cards and fit pills (T18/T07), the scheduler budget (T12) and Diagnostics. Cached in the
// `hardware_profile` table; `HardwareProbe` decides when to re-probe.
import Foundation

public struct HardwareProfile: Codable, Sendable, Equatable {
    /// Display chip name, e.g. "Apple M5 Max".
    public var chip: String
    /// "M5" from "Apple M5 Max"; "A18" for the MacBook Neo; nil for unknown naming.
    public var chipFamily: String?
    public var pCores: Int?
    public var eCores: Int?
    public var gpuCores: Int?
    public var ramGB: Int
    /// `recommendedMaxWorkingSetSize` in GB (1 GB = 1e9 B); nil without Metal.
    public var W: Double?
    /// Memory budget `min(W, RAM − H_os − 0.5)` in GB (hardware-tiers §2.1).
    public var B: Double
    public var tier: HardwareTier
    public var subband: String?
    public var speedClass: SpeedClass
    public var speedClassSource: SpeedClassSource
    /// Memory bandwidth (table or probe); nil for an unknown chip before its MicroProbe.
    public var bandwidthGBs: Double?
    /// Free space on the Models volume (`volumeAvailableCapacityForImportantUsage`), whole GB rounded down.
    public var freeDiskGB: Int
    public var osVersion: String
    public var osBuild: String
    /// "ac" | "battery" | "ups" | nil (IOPSCopyPowerSourcesInfo).
    public var powerSource: String?
    /// Apple Intelligence on-device model available (Normal-only zero-download bridge, K-017).
    public var fmAvailable: Bool
    public var probedAt: Date
    /// The unknown-chip MicroProbe result, kept so it runs once (K-054).
    public var microProbe: MicroProbe.Result?
    /// Set when the profile came from a `-FakeHardware` fixture.
    public var fixture: String?

    /// The tier + sub-band key the catalog's assignments use ("T2-24", or "T1").
    public var tierKey: String { subband ?? tier.rawValue }

    public init(facts: HardwareFacts, classification c: TierClassifier.Result, probedAt: Date = Date(), fixture: String? = nil) {
        chip = facts.brandString
        chipFamily = facts.chipName.split(separator: " ").first.map(String.init)
        pCores = facts.pCores; eCores = facts.eCores; gpuCores = facts.gpuCores
        ramGB = facts.ramGB; W = facts.workingSetGB.map { ($0 * 100).rounded() / 100 }
        B = (c.budgetGB * 100).rounded() / 100
        tier = c.tier; subband = c.subband; speedClass = c.speedClass; speedClassSource = c.speedClassSource
        bandwidthGBs = c.bandwidthGBs
        freeDiskGB = facts.freeDiskBytes.map { Int($0 / 1_000_000_000) } ?? 0
        osVersion = facts.osVersion; osBuild = facts.osBuild; powerSource = facts.powerSource
        fmAvailable = facts.fmAvailable; self.probedAt = probedAt; microProbe = facts.microProbe
        self.fixture = fixture
    }

    /// The single eligibility rule (hardware-tiers §2.1/§5, blueprint E §E.2.3 step 2): a model fits when its
    /// resident footprint plus everything that must stay resident is within B. T06, T18 and T24 call this.
    public func fits(residentGB: Double, mustStayGB: Double) -> Bool {
        residentGB + mustStayGB <= B + 1e-9
    }

    /// Placeholder values of `onb.hardware` ("{chip} · {ram} GB memory · {free} GB available").
    public var hardwareLineArgs: [String: String] {
        ["chip": chip, "ram": String(ramGB), "free": String(freeDiskGB)]
    }

    /// `template` (the `onb.hardware` string) with its placeholders filled.
    public func hardwareLine(template: String) -> String {
        hardwareLineArgs.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
