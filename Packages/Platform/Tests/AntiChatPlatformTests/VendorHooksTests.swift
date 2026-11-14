import Foundation
import Testing
import AntiChatNetwork
@testable import AntiChatPlatform
import OsaurusVendored

/// M0.T14: the vendored closure's hooks are wired to AntiChat (UP-OS-002/008/020) and the
/// UP-OS-000 `package` access rewrite reaches our modules (P-platform-16 "S-1 confirms the
/// package-access approach").
@Suite struct VendorHooksTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("vendorhooks-\(UUID().uuidString)")

    @Test func installRoutesVendoredNetworkingThroughTheGate() {
        VendorHooks.install(dataRoot: root)
        let s = OsaurusNetworkHooks.makeSession(nil, nil, .models)
        defer { s.invalidateAndCancel() }
        #expect(s.configuration.httpCookieStorage == nil)
        #expect(s.configuration.urlCache == nil)
        #expect(OsaurusNetworkHooks.session(.search) === NetworkGate.session(for: .search))
    }

    @Test func installSetsTheSearchProviderDirectory() {
        VendorHooks.install(dataRoot: root)
        #expect(OsaurusPathHooks.searchProviderConfigFile().lastPathComponent == "search.json")
        #expect(OsaurusPathHooks.searchProviderDefinitionsDirectory().deletingLastPathComponent()
            .lastPathComponent == "providers")
    }

    @Test func categoriesMapOneToOne() {
        #expect(VendorHooks.map(.models) == .models)
        #expect(VendorHooks.map(.search) == .search)
        #expect(VendorHooks.map(.mcp) == .mcp)
        #expect(VendorHooks.map(.other) == .other)
    }

    @Test func packageAccessRewriteExposesChipProfile() {
        let chip = ChipProfile.current
        #expect(chip.physicalMemoryBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(chip.brandString.hasPrefix("Apple M"))  // Apple Silicon only (D-001)
        #expect(chip.generation != nil)
        #expect(GPUMemoryBudget.comfortableBudgetRatio == 0.85)
        #expect((ChipProfile.performanceCoreCount() ?? 0) > 0)
    }
}
