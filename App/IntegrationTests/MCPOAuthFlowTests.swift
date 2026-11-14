// M7.T07 / AT-257 c1 (R-257 AC1): the three client-identity modes against the reference AS (`tools/mcp-ref`):
// default → CIMD (the AS fetches AntiChat's metadata document from the local site server), `--no-cimd` → RFC 7591
// DCR, `--no-cimd --no-dcr` → the add form asks for a client ID (`needsClientID`) and the pasted one works. Each
// mode: preview (sign-in) → consent → add → connected → `whoami` answers with the client the token was issued to;
// PKCE method always S256. Plus step 6: an expired access token refreshes on 401 `invalid_token`; a failed refresh
// leaves the row "needs re-auth" (`mcp.authExpired`) without opening a sign-in, and [Sign in again] reconnects.
// Log: build/at/AT-257/<date>.log. Needs Node ≥ 24 (Q-007); without it the test is skipped ("not run").
#if DEBUG
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

final class MCPOAuthFlowTests: XCTestCase {
    var wasOn = false

    override func setUp() async throws {
        try OAuthRef.skipUnlessAvailable()
        wasOn = NetworkPolicyStore.shared.storedValue(.mcp)
    }

    override func tearDown() async throws { NetworkPolicyStore.shared.setEnabled(.mcp, wasOn) }

    /// preview (signs in) → add → connected; returns the host, the row and the `whoami` answer.
    func connect(_ s: OAuthRef.Server, auth: MCPAuthInput = .oauth) async throws -> (MCPHost, MCPServerRecord, String) {
        let host = try OAuthRef.host(s)
        let p = try await host.preview(url: s.mcp, auth: auth)
        XCTAssertEqual(p.tools.map(\.name), ["whoami"])
        let row = try await host.add(name: "OAuth ref", url: s.mcp, auth: auth, preview: p)
        addTeardownBlock { await host.remove(row.id) }
        XCTAssertEqual(row.state, .connected, row.errorCode ?? "")
        XCTAssertEqual(row.authKind, .oauth)
        XCTAssertEqual(row.authRef, KeychainTokenStorage.service, "the DB keeps the Keychain item name only")
        let r = try await host.call(server: row.id, tool: "whoami", argumentsJSON: "{}")
        XCTAssertFalse(r.isError)
        let method = await host.authorizers[row.id]?.lastChallengeMethod
        XCTAssertTrue(method == nil || method == "S256")
        return (host, row, r.text)
    }

    func assertS256(_ s: OAuthRef.Server) async throws {
        let log = try await OAuthRef.asLog(s)
        let auths = log.filter { $0.hasPrefix("authorize ") }
        XCTAssertFalse(auths.isEmpty)
        XCTAssertTrue(auths.allSatisfy { $0.hasSuffix("method=S256") }, "\(auths)")
    }

    func testCIMD() async throws {
        let s = try await OAuthRef.start([], test: self)
        let (_, row, text) = try await connect(s)
        XCTAssertTrue(text.contains("client=\(s.cimd.absoluteString)"), text)
        XCTAssertEqual(KeychainTokenStorage(serverID: row.id).loadRecord().identity, .cimd(s.cimd.absoluteString))
        let log = try await OAuthRef.asLog(s)
        XCTAssertTrue(log.contains { $0.hasPrefix("cimd ") && $0.hasSuffix(" AntiChat") }, "the AS read the CIMD file: \(log)")
        try await assertS256(s)
        OAuthRef.log("c1 cimd: connected, whoami \(text), CIMD served from site/public (local test mode)")
    }

    func testDCR() async throws {
        let s = try await OAuthRef.start(["--no-cimd"], test: self)
        let (_, row, text) = try await connect(s)
        guard case .dcr(let id)? = KeychainTokenStorage(serverID: row.id).loadRecord().identity else { return XCTFail("not DCR") }
        XCTAssertTrue(text.contains("client=\(id)"), text)
        let asl = try await OAuthRef.asLog(s)
        XCTAssertTrue(asl.contains { $0.hasPrefix("dcr ") && $0.hasSuffix(" AntiChat") })
        try await assertS256(s)
        OAuthRef.log("c1 dcr: connected, whoami \(text)")
    }

    func testPastedClientID() async throws {
        let s = try await OAuthRef.start(["--no-cimd", "--no-dcr"], test: self)
        let host = try OAuthRef.host(s)
        do {
            _ = try await host.preview(url: s.mcp, auth: .oauth)
            XCTFail("expected needsClientID")
        } catch {
            XCTAssertEqual(error as? MCPOAuthError, .needsClientID, "\(error)")
        }
        await host.declined()
        let (_, row, text) = try await connect(s, auth: .oauthClientID("antichat-pasted"))
        XCTAssertTrue(text.contains("client=antichat-pasted"), text)
        XCTAssertEqual(KeychainTokenStorage(serverID: row.id).loadRecord().identity, .pasted("antichat-pasted"))
        try await assertS256(s)
        OAuthRef.log("c1 pasted: needsClientID without CIMD/DCR, then connected with the pasted id, whoami \(text)")
    }

    func testRefreshThenReauth() async throws {
        // Default token lifetime (1 h): only the test hook expires access tokens, so a refreshed token cannot expire
        // again mid-reconnect under load, and the client's own expiry clock never triggers a proactive refresh: the
        // refresh below can only come from the 401 invalid_token path.
        let s = try await OAuthRef.start([], test: self)
        let (host, row, _) = try await connect(s)
        let first = try XCTUnwrap(KeychainTokenStorage(serverID: row.id).load()?.value)
        let refreshesBefore = try await OAuthRef.asLog(s).filter { $0.hasPrefix("token refresh ") }.count
        try await OAuthRef.expireAccessTokens(s)
        try await OAuthRef.waitUntilRejected(s, token: first)
        await host.closeAll()  // a fresh session: initialize meets the expired token → 401 invalid_token → refresh
        let r = try await host.call(server: row.id, tool: "whoami", argumentsJSON: "{}")
        XCTAssertFalse(r.isError)
        let asl = try await OAuthRef.asLog(s)
        XCTAssertGreaterThan(asl.filter { $0.hasPrefix("token refresh ") }.count, refreshesBefore, "refreshed")
        let second = try XCTUnwrap(KeychainTokenStorage(serverID: row.id).load()?.value)
        XCTAssertNotEqual(second, first, "the refreshed token replaced the expired one")
        // The AS forgets every token: refresh fails → needs re-auth, no browser opened by itself.
        try await OAuthRef.revokeAll(s)
        try await OAuthRef.waitUntilRejected(s, token: second)
        let before = try await OAuthRef.asLog(s).filter { $0.hasPrefix("authorize ") }.count
        await host.closeAll()
        await host.connect(row.id)
        let after = try XCTUnwrap(try host.repository.server(row.id))
        XCTAssertEqual(after.state, .needsReauth)
        XCTAssertEqual(after.errorCode, "mcp.authExpired")
        XCTAssertNil(KeychainTokenStorage(serverID: row.id).load(), "the dead token is gone")
        let asl2 = try await OAuthRef.asLog(s)
        XCTAssertEqual(asl2.filter { $0.hasPrefix("authorize ") }.count, before, "no unattended sign-in")
        await host.signIn(row.id)
        XCTAssertEqual(try host.repository.server(row.id)?.state, .connected)
        OAuthRef.log("step 6: refresh on 401 invalid_token ok; failed refresh → needsReauth mcp.authExpired; Sign in again → connected")
    }
}
#endif
