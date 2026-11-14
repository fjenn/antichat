// M2.T06 step 2 (R-222; hardware-tiers §3 step 2, blueprint E §E.2.3 step 3): predicted decode = 0.7 × memory
// bandwidth ÷ bytes read per token (`active_gb`, else the weights). Under 15 tok/s the chat cell takes its
// `step_down` entry. Re-checked on the device because the user's bandwidth may differ from the table; a chip
// with no bandwidth yet (unknown chip before its MicroProbe) is not stepped down on a guess.
import Foundation

public enum SpeedGuard {
    public static let floorTokPerSec = 15.0
    public static let efficiency = 0.7

    public static func predictedTokPerSec(_ m: CatalogModel, bandwidthGBs: Double) -> Double {
        let active = m.footprint.activeGB ?? m.footprint.weightsGB
        return active > 0 ? efficiency * bandwidthGBs / active : .infinity
    }

    public static func passes(_ m: CatalogModel, profile: HardwareProfile) -> Bool {
        guard let bw = profile.bandwidthGBs else { return true }
        return predictedTokPerSec(m, bandwidthGBs: bw) >= floorTokPerSec
    }
}
