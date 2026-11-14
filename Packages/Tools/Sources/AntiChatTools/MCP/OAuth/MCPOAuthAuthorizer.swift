// M7.T07 (R-257; P-files-tools-13): OAuth 2.1 for remote MCP servers (MCP spec 2025-11-25 §Authorization), plugged
// into MCPHTTPTransport as swift-sdk's `HTTPClientAuthorizer`. On a 401 it discovers the protected-resource metadata
// (RFC 9728: the challenge's `resource_metadata`, else the well-known URLs), the authorization server's metadata
// (RFC 8414; `issuer` must equal the URL it was fetched for), picks the client identity (ClientIdentity: pasted →
// CIMD → DCR), refuses an AS without PKCE S256, opens the authorization URL (PKCE S256, `state`, RFC 8707 `resource`)
// through the presenter, checks the callback (RFC 9207 `iss` via IssuerCheck, then swift-sdk's
// `OAuthAuthorizationCodeFlow.extractCode`: redirect URI and `state`), exchanges the code and stores the tokens in
// the Keychain (KeychainTokenStorage). A 401 with `invalid_token` refreshes first; a failed refresh clears the token,
// and an unattended connect (launch, reconnect) then stops with `interactionRequired` → the row shows
// "needs re-auth" + [Sign in again] instead of opening a browser by itself.
// swift-sdk pieces used as they are: `PKCE`, `OAuthAuthorizationCodeFlow` (URL + callback parsing),
// `DefaultOAuthMetadataDiscovery` (well-known URLs, canonical resource), `DefaultOAuthWWWAuthenticateParser`,
// `DefaultOAuthScopeSelector`, `OAuthAccessToken`, `TokenStorage`. Its `OAuthAuthorizer` itself is not used
// (A-M7-T07a): it accepts http authorization servers only through a `package`-scoped switch (the local reference
// AS is http://127.0.0.1), has no RFC 9207 check, and sends untagged requests (no `.mcp` ledger row).
// Every request here is tagged `.mcp` on the session the transport passes (the gated one).
import AntiChatNetwork
import Foundation
import MCP

public enum MCPOAuthError: Error, Sendable, Equatable, CustomStringConvertible {
    case discoveryFailed(String)
    case insecureEndpoint(String)
    case pkceS256Unsupported([String])
    case needsClientID
    case registrationFailed(Int)
    case issuerMissing
    case issuerMismatch(expected: String, got: String)
    case callbackRejected(String)
    case authorizationFailed(Int)
    case tokenRequestFailed(Int, String?)
    case interactionRequired
    case cancelled

    public var description: String {
        switch self {
        case .discoveryFailed(let s): "OAuth discovery failed: \(s)"
        case .insecureEndpoint(let s): "insecure OAuth endpoint: \(s)"
        case .pkceS256Unsupported(let m): "the server does not support PKCE S256 (\(m.isEmpty ? "none" : m.joined(separator: ",")))"
        case .needsClientID: "the server needs a client ID"
        case .registrationFailed(let s): "client registration failed (\(s))"
        case .issuerMissing: "the sign-in response has no issuer"
        case .issuerMismatch(let e, let g): "issuer mismatch (expected \(e), got \(g))"
        case .callbackRejected(let s): "sign-in response rejected: \(s)"
        case .authorizationFailed(let s): "authorization failed (\(s))"
        case .tokenRequestFailed(let s, let e): "token request failed (\(s)\(e.map { ", \($0)" } ?? ""))"
        case .interactionRequired: "sign-in required"
        case .cancelled: "sign-in cancelled"
        }
    }

    /// The Connections row's error code.
    public var code: String {
        switch self {
        case .interactionRequired, .cancelled: "mcp.authExpired"
        case .needsClientID: "oauth.needsClientID"
        default: "oauth: \(description)"
        }
    }
}

/// App-wide OAuth settings.
public struct MCPOAuthSettings: Sendable {
    /// The CIMD URL (= AntiChat's client_id at a CIMD-capable AS). Production: the published site file.
    public var cimdURL: URL
    public var redirectURI: URL
    public var clientName: String
    /// Authorization servers on http://127.0.0.1 / localhost (the local reference AS; RFC 8252 loopback). Off in
    /// production builds' defaults; the tests and `-OAuthHeadless` turn it on.
    public var allowLoopbackHTTP: Bool

    public static let cimdProduction = URL(string: "https://antichat.app/oauth/mcp-client-metadata.json")!
    public static let callbackScheme = "antichat"

    public init(cimdURL: URL = Self.cimdProduction, redirectURI: URL = URL(string: "antichat://oauth/callback")!,
                clientName: String = "AntiChat", allowLoopbackHTTP: Bool = false) {
        self.cimdURL = cimdURL
        self.redirectURI = redirectURI
        self.clientName = clientName
        self.allowLoopbackHTTP = allowLoopbackHTTP
    }
}

struct ProtectedResourceMetadata: Decodable, Sendable {
    var resource: String?
    var authorizationServers: [URL]?
    var scopesSupported: [String]?
    enum CodingKeys: String, CodingKey {
        case resource, authorizationServers = "authorization_servers", scopesSupported = "scopes_supported"
    }
}

struct AuthorizationServerMetadata: Decodable, Sendable {
    var issuer: String
    var authorizationEndpoint: URL?
    var tokenEndpoint: URL?
    var registrationEndpoint: URL?
    var codeChallengeMethodsSupported: [String]?
    var clientIDMetadataDocumentSupported: Bool?
    var issParameterSupported: Bool?
    var scopesSupported: [String]?
    enum CodingKeys: String, CodingKey {
        case issuer, authorizationEndpoint = "authorization_endpoint", tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint", codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case clientIDMetadataDocumentSupported = "client_id_metadata_document_supported"
        case issParameterSupported = "authorization_response_iss_parameter_supported", scopesSupported = "scopes_supported"
    }
}

struct TokenResponse: Decodable {
    var accessToken: String
    var tokenType: String?
    var expiresIn: Int?
    var refreshToken: String?
    var scope: String?
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in", refreshToken = "refresh_token", scope
    }
}

public final class MCPOAuthAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
    public let settings: MCPOAuthSettings
    public let store: any MCPOAuthStore
    let presenter: any MCPAuthPresenter
    /// The client ID the user pasted (after CIMD and DCR were both unavailable).
    let pastedClientID: String?
    private let lock = NSLock()
    private var interactive: Bool
    private var discovered: (prm: ProtectedResourceMetadata, asm: AuthorizationServerMetadata)?
    /// The PKCE method of the last authorization request (AT-257 c2 asserts it is always S256).
    public private(set) var lastChallengeMethod: String?

    let discovery = DefaultOAuthMetadataDiscovery()
    let scopes = DefaultOAuthScopeSelector()

    public init(settings: MCPOAuthSettings, store: any MCPOAuthStore, presenter: any MCPAuthPresenter,
                pastedClientID: String? = nil, interactive: Bool) {
        self.settings = settings
        self.store = store
        self.presenter = presenter
        self.pastedClientID = pastedClientID
        self.interactive = interactive
    }

    /// Unattended connects never open the browser.
    public func setInteractive(_ on: Bool) { lock.withLock { interactive = on } }

    public var maxAuthorizationAttempts: Int { 2 }

    public func validateEndpointSecurity(for endpoint: URL) throws { try checkSecure(endpoint, context: "MCP endpoint") }

    func checkSecure(_ url: URL, context: String) throws {
        let scheme = url.scheme?.lowercased(), host = url.host()?.lowercased() ?? ""
        if scheme == "https" { return }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        if scheme == "http", loopback, settings.allowLoopbackHTTP || context == "MCP endpoint" { return }
        throw MCPOAuthError.insecureEndpoint("\(context) \(url.absoluteString)")
    }

    public func authorizationHeader(for endpoint: URL) -> String? {
        store.load().map { "Bearer \($0.value)" }
    }

    public func handleChallenge(statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?,
                                session: URLSession) async throws -> Bool {
        let challenge = DefaultOAuthWWWAuthenticateParser().parseBearer(from: headers)
        let (prm, asm) = try await discover(endpoint: endpoint, challenge: challenge, session: session)
        let resource = try discovery.canonicalResourceURI(from: endpoint)
        let record = store.loadRecord()
        // 401 invalid_token (or an expired token) with a refresh token: refresh first (step 6).
        if statusCode == 401, let t = record.token, let rt = t.refreshToken, let id = record.identity {
            if try await refresh(rt, old: t, identity: id, asm: asm, resource: resource, session: session) { return true }
            store.clear()
        } else if record.token != nil, statusCode == 401 {
            store.clear()
        }
        guard lock.withLock({ interactive }) else { throw MCPOAuthError.interactionRequired }
        let scope = scopes.selectScopes(challengeScope: challenge?.scope, scopesSupported: prm.scopesSupported ?? asm.scopesSupported)
        try await authorize(asm: asm, resource: resource, scope: scope, known: record.identity, session: session)
        return true
    }

    // MARK: Discovery

    func discover(endpoint: URL, challenge: OAuthBearerChallenge?, session: URLSession) async throws
        -> (ProtectedResourceMetadata, AuthorizationServerMetadata) {
        if let d = lock.withLock({ discovered }) { return d }
        var prm: ProtectedResourceMetadata?
        var candidates = discovery.protectedResourceMetadataURLs(for: endpoint)
        if let u = challenge?.resourceMetadataURL { candidates.insert(u, at: 0) }
        for u in candidates {
            guard (try? checkSecure(u, context: "resource metadata")) != nil || u.host() == endpoint.host() else { continue }
            if let m: ProtectedResourceMetadata = try? await getJSON(u, session: session) { prm = m; break }
        }
        guard let prm, let asURL = prm.authorizationServers?.first else { throw MCPOAuthError.discoveryFailed("no protected-resource metadata") }
        if let r = prm.resource.flatMap(URL.init(string:)), !discovery.protectedResourceMatches(resource: r, endpoint: endpoint) {
            throw MCPOAuthError.discoveryFailed("resource \(r.absoluteString) does not match \(endpoint.absoluteString)")
        }
        try checkSecure(asURL, context: "authorization server")
        var asm: AuthorizationServerMetadata?
        for u in discovery.authorizationServerMetadataURLs(for: asURL) {
            if let m: AuthorizationServerMetadata = try? await getJSON(u, session: session) { asm = m; break }
        }
        guard let asm else { throw MCPOAuthError.discoveryFailed("no authorization server metadata at \(asURL.absoluteString)") }
        // RFC 8414 §3.3: the issuer must be the URL the metadata was fetched for.
        guard Self.sameIssuer(asm.issuer, asURL.absoluteString) else {
            throw MCPOAuthError.discoveryFailed("issuer \(asm.issuer) ≠ \(asURL.absoluteString)")
        }
        lock.withLock { discovered = (prm, asm) }
        return (prm, asm)
    }

    static func sameIssuer(_ a: String, _ b: String) -> Bool {
        func n(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        return n(a) == n(b)
    }

    func getJSON<T: Decodable>(_ url: URL, session: URLSession) async throws -> T {
        var r = URLRequest(url: url)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(Version.latest, forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, response) = try await session.data(for: NetworkGate.tag(r, category: .mcp))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MCPOAuthError.discoveryFailed(url.absoluteString) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Authorization code + PKCE

    func authorize(asm: AuthorizationServerMetadata, resource: URL, scope: Set<String>?, known: ClientIdentity?,
                   session: URLSession) async throws {
        guard let authEndpoint = asm.authorizationEndpoint, asm.tokenEndpoint != nil else {
            throw MCPOAuthError.discoveryFailed("no authorization or token endpoint")
        }
        try checkSecure(authEndpoint, context: "authorization endpoint")
        // MCP 2025-11-25 §Authorization: PKCE is required; refuse an AS that does not advertise S256.
        let methods = asm.codeChallengeMethodsSupported ?? []
        guard methods.contains(where: { $0.caseInsensitiveCompare("S256") == .orderedSame }) else {
            throw MCPOAuthError.pkceS256Unsupported(methods)
        }
        let identity = try await ClientIdentity.resolve(metadata: asm, cimdURL: settings.cimdURL, pasted: pastedClientID,
                                                        known: known) { try await self.register($0, session: session) }
        var record = store.loadRecord()
        record.identity = identity
        store.saveRecord(record)
        let verifier = PKCE.makeVerifier()
        let challenge = try PKCE.makeChallenge(from: verifier)
        let state = UUID().uuidString
        let flow = OAuthAuthorizationCodeFlow()
        let url = try flow.buildURL(authorizationEndpoint: authEndpoint, resource: resource, redirectURI: settings.redirectURI,
                                    clientID: identity.clientID, codeChallenge: challenge, scopes: scope, state: state,
                                    scopeSerializer: scopes)
        lock.withLock { lastChallengeMethod = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code_challenge_method" }?.value }
        let callback = try await presenter.present(url, callbackScheme: MCPOAuthSettings.callbackScheme)
        if let e = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw MCPOAuthError.callbackRejected(e)
        }
        try IssuerCheck.verify(callback: callback, issuer: asm.issuer, advertised: asm.issParameterSupported == true)
        let code: String
        do {
            code = try flow.extractCode(from: callback, expectedRedirectURI: settings.redirectURI, expectedState: state)
        } catch {
            throw MCPOAuthError.callbackRejected(Self.reason(error))
        }
        let t = try await tokenRequest(asm: asm, session: session, form: [
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": settings.redirectURI.absoluteString, "client_id": identity.clientID, "resource": resource.absoluteString,
        ])
        store.save(token(t, asm: asm, identity: identity, oldRefresh: nil, requested: scope))
    }

    static func reason(_ e: any Error) -> String {
        guard let o = e as? OAuthAuthorizationError else { return "\(e)" }
        switch o {
        case .authorizationResponseStateMismatch: return "state mismatch"
        case .authorizationResponseMissingState: return "state missing"
        case .authorizationResponseRedirectMismatch: return "redirect_uri mismatch"
        case .authorizationResponseMissingCode: return "code missing"
        default: return o.errorDescription ?? "\(o)"
        }
    }

    func refresh(_ refreshToken: String, old: OAuthAccessToken, identity: ClientIdentity, asm: AuthorizationServerMetadata,
                 resource: URL, session: URLSession) async throws -> Bool {
        do {
            let t = try await tokenRequest(asm: asm, session: session, form: [
                "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": identity.clientID,
                "resource": resource.absoluteString,
            ])
            store.save(token(t, asm: asm, identity: identity, oldRefresh: refreshToken, requested: old.scopes))
            return true
        } catch MCPOAuthError.tokenRequestFailed(let status, _) where (400..<500).contains(status) {
            return false
        }
    }

    func token(_ t: TokenResponse, asm: AuthorizationServerMetadata, identity: ClientIdentity, oldRefresh: String?,
               requested: Set<String>?) -> OAuthAccessToken {
        OAuthAccessToken(value: t.accessToken, tokenType: "Bearer", expiresAt: t.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
                         scopes: t.scope.map(scopes.parseScopeString) ?? requested ?? [], authorizationServer: URL(string: asm.issuer),
                         refreshToken: t.refreshToken ?? oldRefresh, clientID: identity.clientID)
    }

    func tokenRequest(asm: AuthorizationServerMetadata, session: URLSession, form: [String: String]) async throws -> TokenResponse {
        guard let endpoint = asm.tokenEndpoint else { throw MCPOAuthError.discoveryFailed("no token endpoint") }
        try checkSecure(endpoint, context: "token endpoint")
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.rfc6749Encoded)" }.joined(separator: "&").utf8)
        let (data, response) = try await session.data(for: NetworkGate.tag(r, category: .mcp))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let t = try? JSONDecoder().decode(TokenResponse.self, from: data), !t.accessToken.isEmpty else {
            let e = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw MCPOAuthError.tokenRequestFailed(status, e)
        }
        return t
    }

    /// RFC 7591 dynamic registration of a public client (`token_endpoint_auth_method: none`).
    func register(_ endpoint: URL, session: URLSession) async throws -> String {
        try checkSecure(endpoint, context: "registration endpoint")
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": settings.clientName, "redirect_uris": [settings.redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await session.data(for: NetworkGate.tag(r, category: .mcp))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = o["client_id"] as? String, !id.isEmpty else { throw MCPOAuthError.registrationFailed(status) }
        return id
    }
}

extension String {
    /// application/x-www-form-urlencoded (RFC 6749 §2.3.1 / Appendix B): only unreserved characters stay.
    var rfc6749Encoded: String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
