// M7.T07 / AT-257 c2 (R-257 AC2): every tampered or weak authorization is rejected — no token is stored (the
// Keychain record has no token) and the row shows the error — against the reference AS (`tools/mcp-ref`):
// `--bad-state` (callback state ≠ ours), `--bad-iss` (RFC 9207 issuer mix-up), `--plain-pkce` (AS offers only
// `plain`), `--no-pkce` (AS advertises no PKCE), code replay (a used code injected into a fresh callback: the AS
// refuses it and revokes what it issued), redirect_uri mismatch (the AS redirects elsewhere; and an unregistered
// redirect_uri, which the AS refuses to redirect to). PKCE method is S256 on every authorization request sent.
#if DEBUG
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

final class OAuthNegativeTests: XCTestCase {
    var wasOn = false

    override func setUp() async throws {
        try OAuthRef.skipUnlessAvailable()
        wasOn = NetworkPolicyStore.shared.storedValue(.mcp)
    }

    override func tearDown() async throws { NetworkPolicyStore.shared.setEnabled(.mcp, wasOn) }

    /// Adds the server (sign-in during connect) and asserts it is rejected: not connected, an error on the row, no
    /// token in the Keychain record.
    @discardableResult
    func assertRejected(_ toggles: [String], presenter: (any MCPAuthPresenter)? = nil, redirect: URL? = nil,
                        expect: String, expectLog: String? = nil,
                        file: StaticString = #filePath, line: UInt = #line) async throws -> MCPServerRecord {
        let s = try await OAuthRef.start(toggles, test: self)
        let host = try OAuthRef.host(s, presenter: presenter ?? HeadlessAuthPresenter(),
                                     redirect: redirect ?? URL(string: "antichat://oauth/callback")!)
        let row = try await host.add(name: "OAuth ref", url: s.mcp, auth: .oauth)
        addTeardownBlock { await host.remove(row.id) }
        let after = try XCTUnwrap(try host.repository.server(row.id), file: file, line: line)
        XCTAssertNotEqual(after.state, .connected, file: file, line: line)
        let code = after.errorCode ?? ""
        XCTAssertTrue(code.contains(expect), "\(toggles): \(code)", file: file, line: line)
        XCTAssertNil(KeychainTokenStorage(serverID: row.id).load(), "\(toggles): a token was stored", file: file, line: line)
        let asLog = try await OAuthRef.asLog(s)
        if let expectLog {  // the specific rejection, not just its status (an unreachable client document is also 400)
            let rejects = asLog.filter { $0.hasPrefix("reject ") }
            XCTAssertFalse(rejects.isEmpty, "\(toggles): the AS logged no rejection", file: file, line: line)
            XCTAssertTrue(rejects.allSatisfy { $0.hasPrefix(expectLog) }, "\(toggles): \(rejects)", file: file, line: line)
            XCTAssertFalse(asLog.contains { $0.hasPrefix("cimd fetch failed") || $0.hasPrefix("server_error") }, "\(asLog)",
                           file: file, line: line)
        }
        let auths = asLog.filter { $0.hasPrefix("authorize ") }
        XCTAssertTrue(auths.allSatisfy { $0.hasSuffix("method=S256") }, "\(auths)", file: file, line: line)
        OAuthRef.log("c2 \(toggles.joined(separator: " ")) rejected: state=\(after.state.rawValue) error=\(code)")
        return after
    }

    func testBadState() async throws { try await assertRejected(["--bad-state"], expect: "state mismatch") }
    func testBadIssuer() async throws { try await assertRejected(["--bad-iss"], expect: "issuer mismatch") }
    func testPlainPKCE() async throws { try await assertRejected(["--plain-pkce"], expect: "PKCE S256") }
    func testNoPKCE() async throws { try await assertRejected(["--no-pkce"], expect: "PKCE S256") }
    func testRedirectMismatch() async throws { try await assertRejected(["--bad-redirect"], expect: "redirect_uri mismatch") }

    func testUnregisteredRedirectURI() async throws {
        try await assertRejected([], redirect: URL(string: "antichat://oauth/not-registered")!, expect: "authorization failed (400)",
                                 expectLog: "reject invalid_request: redirect_uri not registered")
    }

    func testCodeReplay() async throws {
        let s = try await OAuthRef.start([], test: self)
        let presenter = ReplayingPresenter()
        let host = try OAuthRef.host(s, presenter: presenter)
        let first = try await host.add(name: "OAuth ref", url: s.mcp, auth: .oauth)  // uses the code once
        addTeardownBlock { await host.remove(first.id) }
        XCTAssertEqual(try host.repository.server(first.id)?.state, .connected)
        let second = try await host.add(name: "OAuth ref 2", url: s.mcp, auth: .oauth)  // the same code again
        addTeardownBlock { await host.remove(second.id) }
        let row = try XCTUnwrap(try host.repository.server(second.id))
        XCTAssertNotEqual(row.state, .connected)
        XCTAssertTrue((row.errorCode ?? "").contains("invalid_grant"), row.errorCode ?? "")
        XCTAssertNil(KeychainTokenStorage(serverID: second.id).load())
        let asl = try await OAuthRef.asLog(s)
        XCTAssertTrue(asl.contains("replay rejected"))
        // OAuth 2.1 §4.1.3: the replay revoked the first grant's tokens too.
        await host.closeAll()
        await host.connect(first.id)
        XCTAssertNotEqual(try host.repository.server(first.id)?.state, .connected)
        OAuthRef.log("c2 code replay rejected (invalid_grant), first grant revoked")
    }
}
#endif
