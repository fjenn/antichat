// M7.T07 step 4 (R-257 AC2, NFR-SEC4): a connection's OAuth tokens live in the Keychain only: service
// `app.antichat.mcp.oauth`, account `<server_id>`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (via
// KeychainSecrets). The item holds the access + refresh token and the client identity (JSON); the DB keeps only
// `mcp_server.auth_ref` = the service name. Conforms to swift-sdk's `TokenStorage`. A preview (before the row
// exists) uses `MemoryOAuthStore`; `MCPHost.add` moves it into the Keychain under the new id.
import Foundation
import MCP

public struct MCPOAuthRecord: Codable, Sendable {
    public var token: OAuthAccessToken?
    public var identity: ClientIdentity?
    public init(token: OAuthAccessToken? = nil, identity: ClientIdentity? = nil) { self.token = token; self.identity = identity }
}

/// Where an authorizer keeps its record.
public protocol MCPOAuthStore: TokenStorage {
    func loadRecord() -> MCPOAuthRecord
    func saveRecord(_ r: MCPOAuthRecord)
}

extension MCPOAuthStore {
    public func save(_ token: OAuthAccessToken) { var r = loadRecord(); r.token = token; saveRecord(r) }
    public func load() -> OAuthAccessToken? { loadRecord().token }
    public func clear() { var r = loadRecord(); r.token = nil; saveRecord(r) }
}

public final class KeychainTokenStorage: MCPOAuthStore, @unchecked Sendable {
    public static let service = "app.antichat.mcp.oauth"
    public let serverID: String
    let secrets: any MCPSecretStore
    private let lock = NSLock()

    public init(serverID: String, secrets: any MCPSecretStore = KeychainSecrets()) {
        self.serverID = serverID
        self.secrets = secrets
    }

    public func loadRecord() -> MCPOAuthRecord {
        lock.withLock {
            guard let s = secrets.read(service: Self.service, account: serverID),
                  let r = try? JSONDecoder().decode(MCPOAuthRecord.self, from: Data(s.utf8)) else { return MCPOAuthRecord() }
            return r
        }
    }

    public func saveRecord(_ r: MCPOAuthRecord) {
        lock.withLock {
            guard r.token != nil || r.identity != nil,
                  let d = try? JSONEncoder().encode(r), let s = String(data: d, encoding: .utf8) else {
                secrets.delete(service: Self.service, account: serverID)
                return
            }
            try? secrets.write(s, service: Self.service, account: serverID)
        }
    }

    /// Removes the item (connection removed).
    public func deleteAll() { lock.withLock { secrets.delete(service: Self.service, account: serverID) } }
}

/// In-memory record (the add flow's preview, before a row id exists).
public final class MemoryOAuthStore: MCPOAuthStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = MCPOAuthRecord()
    public init(_ r: MCPOAuthRecord = MCPOAuthRecord()) { record = r }
    public func loadRecord() -> MCPOAuthRecord { lock.withLock { record } }
    public func saveRecord(_ r: MCPOAuthRecord) { lock.withLock { record = r } }
}
