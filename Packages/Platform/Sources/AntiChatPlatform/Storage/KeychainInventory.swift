// M8.T10 step 1/7 (NFR-D7): AntiChat's Keychain items — generic passwords whose service starts with `app.antichat.`
// (MCP bearer / OAuth tokens `app.antichat.mcp.<server>` (M7 G-031), the Composio install id and BYO search keys when
// those land (G-033, G-029)). Enumerated, not hard-coded, so a new service is never left behind; Remove everything and
// Uninstall delete each one (`SecItemDelete`). `tools/ci/zero-files.sh` re-checks with `security dump-keychain`.
import Foundation
import Security

public enum KeychainInventory {
    /// Every generic-password service with `prefix` this process can see (sorted, unique).
    public static func services(prefix: String = DataPaths.keychainPrefix) -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return Array(Set(items.compactMap { $0[kSecAttrService as String] as? String }.filter { $0.hasPrefix(prefix) })).sorted()
    }

    /// Deletes every item of each service; returns the services that still have items afterwards.
    @discardableResult
    public static func deleteAll(prefix: String = DataPaths.keychainPrefix) -> [String] {
        for s in services(prefix: prefix) {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s] as CFDictionary)
        }
        return services(prefix: prefix)
    }
}
