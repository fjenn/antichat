// M7.T07 (R-257): the pieces of the OAuth flow that need no server — RFC 9207 issuer check, client identity order
// (pasted → CIMD → DCR → needs client ID), the Keychain record (service/account, nothing but tokens + identity), and
// the CIMD document's schema (`site/public/oauth/mcp-client-metadata.json`, definition of done). The full flow and
// the negative cases run against `tools/mcp-ref` in App/IntegrationTests (MCPOAuthFlowTests, OAuthNegativeTests).
@testable import AntiChatTools
import Foundation
import MCP
import Testing

struct MCPOAuthUnitTests {
    @Test func testIssuerCheck() throws {
        let ok = URL(string: "antichat://oauth/callback?code=c&state=s&iss=https%3A%2F%2Fas.example")!
        try IssuerCheck.verify(callback: ok, issuer: "https://as.example", advertised: true)
        let bad = URL(string: "antichat://oauth/callback?code=c&state=s&iss=https%3A%2F%2Fevil.example")!
        #expect(throws: MCPOAuthError.issuerMismatch(expected: "https://as.example", got: "https://evil.example")) {
            try IssuerCheck.verify(callback: bad, issuer: "https://as.example", advertised: true)
        }
        #expect(throws: MCPOAuthError.self) { try IssuerCheck.verify(callback: bad, issuer: "https://as.example", advertised: false) }  // present ⇒ compared
        let none = URL(string: "antichat://oauth/callback?code=c&state=s")!
        #expect(throws: MCPOAuthError.issuerMissing) { try IssuerCheck.verify(callback: none, issuer: "https://as.example", advertised: true) }
        try IssuerCheck.verify(callback: none, issuer: "https://as.example", advertised: false)
    }

    func metadata(cimd: Bool?, dcr: Bool) throws -> AuthorizationServerMetadata {
        var o: [String: Any] = ["issuer": "https://as.example", "authorization_endpoint": "https://as.example/a",
                                "token_endpoint": "https://as.example/t", "code_challenge_methods_supported": ["S256"]]
        if let cimd { o["client_id_metadata_document_supported"] = cimd }
        if dcr { o["registration_endpoint"] = "https://as.example/register" }
        return try JSONDecoder().decode(AuthorizationServerMetadata.self, from: JSONSerialization.data(withJSONObject: o))
    }

    @Test func testClientIdentityOrder() async throws {
        let cimd = MCPOAuthSettings.cimdProduction
        var registered = 0
        let register: (URL) async throws -> String = { _ in registered += 1; return "dcr-1" }
        let a = try await ClientIdentity.resolve(metadata: metadata(cimd: true, dcr: true), cimdURL: cimd, pasted: nil, known: nil, register: register)
        #expect(a == .cimd(cimd.absoluteString))
        let b = try await ClientIdentity.resolve(metadata: metadata(cimd: false, dcr: true), cimdURL: cimd, pasted: nil, known: nil, register: register)
        #expect(b == .dcr("dcr-1"))
        let reused = try await ClientIdentity.resolve(metadata: metadata(cimd: nil, dcr: true), cimdURL: cimd, pasted: nil, known: b, register: register)
        #expect(reused == .dcr("dcr-1"))
        #expect(registered == 1, "a registered client is reused")
        do {
            _ = try await ClientIdentity.resolve(metadata: metadata(cimd: false, dcr: false), cimdURL: cimd, pasted: nil, known: nil, register: register)
            Issue.record("expected needsClientID")
        } catch { #expect(error as? MCPOAuthError == .needsClientID) }
        let p = try await ClientIdentity.resolve(metadata: metadata(cimd: false, dcr: false), cimdURL: cimd, pasted: " my-app ", known: nil, register: register)
        #expect(p == .pasted("my-app"))
    }

    @Test func testKeychainRecordHoldsOnlyTokensAndIdentity() throws {
        let secrets = MemorySecrets()
        let s = KeychainTokenStorage(serverID: "srv-1", secrets: secrets)
        #expect(s.load() == nil)
        s.save(OAuthAccessToken(value: "at_x", tokenType: "Bearer", expiresAt: nil, scopes: ["mcp:tools"],
                                authorizationServer: URL(string: "https://as.example"), refreshToken: "rt_x", clientID: "c"))
        #expect(Array(secrets.all.keys) == ["app.antichat.mcp.oauth/srv-1"])
        #expect(s.load()?.refreshToken == "rt_x")
        var r = s.loadRecord()
        r.identity = .dcr("c")
        s.saveRecord(r)
        #expect(KeychainTokenStorage(serverID: "srv-1", secrets: secrets).loadRecord().identity == .dcr("c"))
        s.clear()
        #expect(s.load() == nil)
        #expect(s.loadRecord().identity == .dcr("c"), "the client identity outlives a cleared token")
        s.deleteAll()
        #expect(secrets.all.isEmpty)
    }

    /// Definition of done: the CIMD file in `site/` matches the client metadata the app sends.
    @Test func testCIMDDocumentSchema() throws {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { u.deleteLastPathComponent() }
        let file = u.appendingPathComponent("site/public/oauth/mcp-client-metadata.json")
        let o = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(o["client_id"] as? String == MCPOAuthSettings.cimdProduction.absoluteString, "client_id = its own URL")
        #expect(o["client_name"] as? String == "AntiChat")
        #expect(o["redirect_uris"] as? [String] == ["http://127.0.0.1/callback", "antichat://oauth/callback"])
        #expect((o["redirect_uris"] as? [String] ?? []).contains(MCPOAuthSettings().redirectURI.absoluteString))
        #expect(o["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(o["token_endpoint_auth_method"] as? String == "none")
        for k in ["logo_uri", "client_uri", "policy_uri"] {
            #expect(URL(string: o[k] as? String ?? "")?.scheme == "https", "\(k)")
        }
    }

    @Test func testFormEncoding() {
        #expect("antichat://oauth/callback".rfc6749Encoded == "antichat%3A%2F%2Foauth%2Fcallback")
        #expect("a b+c".rfc6749Encoded == "a%20b%2Bc")
    }
}
