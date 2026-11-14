// M7.T06 step 4 (R-081, NFR-SEC4): a pasted bearer token lives in the Keychain only (service
// `app.antichat.mcp.<server id>`, account `token`, this device only, after first unlock). The DB keeps the item name
// (`mcp_server.auth_ref`), never the secret. Tests use `MemorySecrets`.
import AntiChatFoundation
import Foundation
import Security

public protocol MCPSecretStore: Sendable {
    func read(service: String, account: String) -> String?
    func write(_ value: String, service: String, account: String) throws
    func delete(service: String, account: String)
}

public struct KeychainSecrets: MCPSecretStore {
    /// A throwaway dev container (`-ANTICHAT_DEV_CONTAINER`, DEBUG: UI tests, probes) keeps its secrets in the container
    /// instead of the login keychain (Q-015 r3). There, an item an earlier ad-hoc-signed build created (the Composio
    /// install ID) made every read open the "wants to use your confidential information" prompt, which blocked the
    /// calling thread until someone typed the Mac's password: Composio Connect opened nothing and said nothing, and
    /// tests wrote into the owner's keychain. nil = the keychain (always in Release).
    let container: FileSecrets?

    public init() { self.init(containerPath: Self.devContainerPath) }

    init(containerPath: String?) {
        container = containerPath.map { FileSecrets(url: URL(fileURLWithPath: $0, isDirectory: true).appending(path: "Secrets/secrets.json")) }
    }

    static var devContainerPath: String? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        LaunchOptions.current.devContainer
        #else
        nil
        #endif
    }

    func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(service: String, account: String) -> String? {
        if let container { return container.read(service: service, account: account) }
        var q = query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public func write(_ value: String, service: String, account: String) throws {
        if let container { return try container.write(value, service: service, account: account) }
        delete(service: service, account: account)
        var q = query(service, account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public func delete(service: String, account: String) {
        if let container { return container.delete(service: service, account: account) }
        SecItemDelete(query(service, account) as CFDictionary)
    }
}

/// The dev container's secret file (DEBUG automation runs only; see `KeychainSecrets.container`): owner-only JSON.
final class FileSecrets: MCPSecretStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    init(url: URL) { self.url = url }

    private func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    private func save(_ items: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(items).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func read(service: String, account: String) -> String? { lock.withLock { load()["\(service)/\(account)"] } }
    func write(_ value: String, service: String, account: String) throws {
        try lock.withLock { var i = load(); i["\(service)/\(account)"] = value; try save(i) }
    }
    func delete(service: String, account: String) {
        lock.withLock { var i = load(); if i.removeValue(forKey: "\(service)/\(account)") != nil { try? save(i) } }
    }
}

public final class MemorySecrets: MCPSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    public init() {}
    public func read(service: String, account: String) -> String? { lock.withLock { items["\(service)/\(account)"] } }
    public func write(_ value: String, service: String, account: String) throws { lock.withLock { items["\(service)/\(account)"] = value } }
    public func delete(service: String, account: String) { _ = lock.withLock { items.removeValue(forKey: "\(service)/\(account)") } }
    public var all: [String: String] { lock.withLock { items } }
}

public enum MCPSecretNames {
    public static func tokenService(_ serverID: String) -> String { "app.antichat.mcp.\(serverID)" }
    public static let tokenAccount = "token"
}
