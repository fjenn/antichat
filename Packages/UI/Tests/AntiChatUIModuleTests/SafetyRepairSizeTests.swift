// M4 review P2 (R-285 AC6, `safety.missing` repair size): a job's detector manifest comes from the catalog even when
// the selection has no `csam_check` slot, so a missing check shows its real download size (never 0 B); the
// install-time preparation still requires the slot.
import AntiChatFoundation
import AntiChatPlatform
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct SafetyRepairSizeTests {
    @Test func manifestCarriesCatalogSizeWithoutSlot() throws {
        let model = OnboardingModelTests.model(.T3)
        var sel = try #require(model.selection)
        sel.slots.removeAll { $0.role == "csam_check" }
        let installs = FileManager.default.temporaryDirectory.appendingPathComponent("no-installs-\(UUID().uuidString)")
        let m = try #require(InstalledPhotoModels.safety(selection: sel, catalog: OnboardingModelTests.catalog, installs: installs,
                                                         requireSlot: false))
        #expect(m.sizeBytes > 100_000_000, "repair size from the catalog")
        #expect(InstalledPhotoModels.safety(selection: sel, catalog: OnboardingModelTests.catalog, installs: installs) == nil)
    }
}
