// M7.T11 step 1 (R-255 AC2, architecture §8.2): the pseudonymous install ID the Composio relay keys a user by
// (`userId = "ac_" + HMAC(secret, installId)` on the relay; the app never sees a Composio identity). A UUIDv4 created
// at the first Connections use that needs the relay (opening Settings › Connections or a chat's Connect card, which
// ask the relay which apps exist; connecting an app) — never during onboarding, never at launch — and kept in the Keychain
// (service `app.antichat.composio.install`, this device only). Remove everything / Uninstall deletes it after
// `/v1/forget` (M8 calls `forget`).
import Foundation

public struct InstallID: Sendable {
    public static let service = "app.antichat.composio.install"
    public static let account = "install"

    let secrets: any MCPSecretStore
    public init(secrets: any MCPSecretStore = KeychainSecrets()) { self.secrets = secrets }

    /// The stored ID, if one was ever created (never creates one).
    public var existing: String? {
        guard let v = secrets.read(service: Self.service, account: Self.account), Self.isUUIDv4(v) else { return nil }
        return v
    }

    /// The ID, created on first use.
    public func current() throws -> String {
        if let v = existing { return v }
        let v = UUID().uuidString.lowercased()  // Foundation's UUID() is a random (version 4) UUID
        try secrets.write(v, service: Self.service, account: Self.account)
        return v
    }

    public func delete() { secrets.delete(service: Self.service, account: Self.account) }

    static func isUUIDv4(_ s: String) -> Bool {
        s.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }
}
