// M2.T06 step 1 (R-222, NFR-R5; blueprint E §E.2.3 step 2, hardware-tiers §2.1/§5): the one memory rule.
//   resident(model, ctx) = weights_gb + kv_per_token_kb × ctx / 1e6 + overhead_gb
//   eligible ⇔ resident + mustStay ≤ B        (HardwareProfile.fits, shared with T18/T24)
// The same arithmetic gives the FitPill class (T07): Fits ≤ 0.85 B, Tight ≤ B, TooLarge > B.
import Foundation

public enum FitClass: String, Codable, Sendable, Equatable { case fits, tight, tooLarge }

public enum FitRule {
    public static let comfortableShare = 0.85

    public static func resident(_ m: CatalogModel, ctx: Int) -> Double {
        m.footprint.weightsGB + m.footprint.kvPerTokenKB * Double(ctx) / 1e6 + m.footprint.overheadGB
    }

    /// A model loaded without a KV cache (embeddings, voice, image parts): weights + overhead.
    public static func resident(_ m: CatalogModel) -> Double { resident(m, ctx: 0) }

    public static func classify(residentGB: Double, mustStayGB: Double, profile: HardwareProfile) -> FitClass {
        let total = residentGB + mustStayGB
        if total <= comfortableShare * profile.B + 1e-9 { return .fits }
        return profile.fits(residentGB: residentGB, mustStayGB: mustStayGB) ? .tight : .tooLarge
    }
}

/// M2.T06 step 3 (blueprint E §E.2.3 step 4): {8K, 16K, 32K, 64K, 128K}. The chosen context is the largest rung up
/// to the cell's default that still fits; landing below the default is never silent (`model.contextLowered`).
public enum ContextLadder {
    public static let rungs = [8192, 16384, 32768, 65536, 131072]

    /// nil when not even 8K fits.
    public static func choose(_ m: CatalogModel, cellDefault: Int, mustStayGB: Double, profile: HardwareProfile) -> Int? {
        let cap = min(cellDefault, m.contextMax ?? cellDefault)
        return rungs.filter { $0 <= max(cap, rungs[0]) }.reversed()
            .first { profile.fits(residentGB: FitRule.resident(m, ctx: $0), mustStayGB: mustStayGB) }
    }
}
