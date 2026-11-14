// Installs the hooks the vendored Osaurus closure exposes (M0.T14 step 3; UP-OS-002, UP-OS-003,
// UP-OS-008, UP-OS-009, UP-OS-020 in Vendor/UPSTREAM_PATCHES.md). OsaurusVendored has no import edge
// to AntiChatNetwork (architecture.md §3), so the gate is injected here, once, at launch.
import Foundation
import AntiChatNetwork
import OsaurusVendored

public enum VendorHooks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    /// Idempotent. `dataRoot` is AntiChat's Application Support directory (environment.md §6).
    public static func install(dataRoot: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        OsaurusNetworkHooks.makeSession = { configuration, delegate, category in
            NetworkGate.session(for: map(category), configuration: configuration, delegate: delegate)
        }
        OsaurusNetworkHooks.session = { NetworkGate.session(for: map($0)) }
        // D-03: the Network activity list is M2 G-056; until then the hook stays a no-op.
        let providers = dataRoot.appendingPathComponent("providers", isDirectory: true)
        OsaurusPathHooks.searchProvidersDirectory = { providers }
        SwapPressureMonitor.emulationRoot = dataRoot
    }

    static func map(_ c: OsaurusNetworkCategory) -> NetworkCategory {
        switch c {
        case .models: .models
        case .search: .search
        case .mcp: .mcp
        case .other: .other
        }
    }
}
