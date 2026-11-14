// M7.T07 step 2 (R-257 AC1): which OAuth client AntiChat is at a given authorization server. Order: a client ID the
// user pasted (the `conn.mcp.clientId` field, shown only after the two automatic ways failed) → CIMD (the AS
// advertises `client_id_metadata_document_supported`: the client_id is the URL of AntiChat's published metadata
// document, `site/public/oauth/mcp-client-metadata.json`) → RFC 7591 dynamic registration → `needsClientID`.
// A registered (DCR) client id is kept with the token in the Keychain, so a later sign-in reuses it.
import Foundation

public enum ClientIdentity: Sendable, Equatable, Codable {
    case cimd(String)
    case dcr(String)
    case pasted(String)

    public var clientID: String {
        switch self {
        case .cimd(let s), .dcr(let s), .pasted(let s): s
        }
    }

    public var kind: String {
        switch self {
        case .cimd: "cimd"
        case .dcr: "dcr"
        case .pasted: "pasted"
        }
    }

    /// Picks the identity for `metadata`. `known` is a previous identity for this server (a DCR client is reused
    /// while the AS still has a registration endpoint); `register` performs RFC 7591 registration.
    static func resolve(metadata: AuthorizationServerMetadata, cimdURL: URL, pasted: String?, known: ClientIdentity?,
                        register: (URL) async throws -> String) async throws -> ClientIdentity {
        if let p = pasted?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { return .pasted(p) }
        if metadata.clientIDMetadataDocumentSupported == true { return .cimd(cimdURL.absoluteString) }
        if let endpoint = metadata.registrationEndpoint {
            if case .dcr = known { return known! }
            return .dcr(try await register(endpoint))
        }
        if case .pasted = known { return known! }
        throw MCPOAuthError.needsClientID
    }
}
