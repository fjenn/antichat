// M7.T11 step 2 (R-255, architecture §8.2; D-007): the app side of the AntiChat Composio relay. Every request goes
// through the gate as `.relay` (one ledger row each) with the headers §8.2 fixes: `X-AntiChat-Install` (InstallID),
// `X-AntiChat-Version`, `User-Agent: AntiChat/<ver>`. The relay holds the Composio key; the app never sees it nor any
// Composio header. Base URL: Debug `-RelayURL <url>` → `Endpoints.plist` `RelayURL` → `http://127.0.0.1:3000`
// (`make relay-dev`). Relay error bodies `{code: "relay.*"}` map to AntiChatError (domain `relay`, the copy key is
// the code: `relay.notConfigured`, `.rateLimited`, `.overCapacity`, `.disabled`, `.updateRequired`).
import AntiChatFoundation
import AntiChatNetwork
import Foundation

/// One app the relay can link (a Composio toolkit) and its state for this install.
public struct RelayConnection: Sendable, Equatable, Decodable {
    public var id: String
    public var toolkit: String
    public var status: String
    public var isActive: Bool { status.uppercased() == "ACTIVE" }
}

public struct RelayConnections: Sendable, Equatable, Decodable {
    public var toolkits: [String]
    public var connections: [RelayConnection]
}

public struct RelayClient: Sendable {
    public static let codes: Set<String> = ["notConfigured", "rateLimited", "overCapacity", "disabled", "updateRequired"]

    public let baseURL: URL
    let installID: InstallID
    let session: @Sendable () -> GatedSession
    let version: String

    public init(baseURL: URL = RelayClient.endpoint(), installID: InstallID = InstallID(),
                session: @escaping @Sendable () -> GatedSession = { NetworkGate.gated(.relay) },
                version: String = RelayClient.appVersion) {
        self.baseURL = baseURL
        self.installID = installID
        self.session = session
        self.version = version
    }

    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `-RelayURL <url>` (Debug) → `Endpoints.plist` `RelayURL` in the app bundle → the local dev relay.
    public static func endpoint(options: LaunchOptions = .current, bundle: Bundle = .main) -> URL {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let s = options.relayURL, let u = URL(string: s) { return u }
        #endif
        if let p = bundle.url(forResource: "Endpoints", withExtension: "plist"),
           let d = NSDictionary(contentsOf: p), let s = d["RelayURL"] as? String, let u = URL(string: s) { return u }
        return URL(string: "http://127.0.0.1:3000")!
    }

    /// Whether this build has a deployed relay (no relay = the Composio connectors are hidden, as in release 1). Debug
    /// and the perf harness always do (`make relay-dev`, `-RelayURL`); a release build only for an https URL on a
    /// public dotted host, never the loopback fallback (an empty `RelayURL` in Endpoints.plist = no relay).
    public static func isAvailable(options: LaunchOptions = .current, bundle: Bundle = .main) -> Bool {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        return true
        #else
        return isDeployed(endpoint(options: options, bundle: bundle))
        #endif
    }

    /// An https URL on a public dotted host (not loopback): the rule of `tools/ci/endpoints-check.py` `relay_ok`.
    public static func isDeployed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased(), host.contains(".") else { return false }
        return !(host == "localhost" || host == "0.0.0.0" || host.hasPrefix("127.") || host.hasPrefix("["))
    }

    /// The MCP endpoint (the Composio row's `url_or_cmd`).
    public var mcpURL: URL { baseURL.appending(path: "v1/mcp") }

    /// §8.2 headers (creates the install ID: only call from a Connections action).
    public func headers() throws -> [String: String] {
        ["X-AntiChat-Install": try installID.current(), "X-AntiChat-Version": version, "User-Agent": "AntiChat/\(version)"]
    }

    // MARK: Calls

    public func health() async throws -> Bool {
        let (d, _) = try await send("GET", "v1/health", auth: false)
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["ok"] as? Bool ?? false
    }

    public func createSession() async throws { _ = try await send("POST", "v1/session") }

    public func connections() async throws -> RelayConnections {
        let (d, _) = try await send("GET", "v1/connections")
        do { return try JSONDecoder().decode(RelayConnections.self, from: d) } catch {
            throw AntiChatError(.toolFailed, detail: "relay connections: bad body")
        }
    }

    /// The hosted sign-in URL for `toolkit` (opened in the user's browser).
    public func link(toolkit: String) async throws -> URL {
        let body = try JSONSerialization.data(withJSONObject: ["toolkit": toolkit])
        let (d, _) = try await send("POST", "v1/connections/link", body: body)
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = o["url"] as? String,
              let u = URL(string: s), ["https", "http"].contains(u.scheme ?? "") else {
            throw AntiChatError(.toolFailed, detail: "relay link: bad body")
        }
        return u
    }

    public func disconnect(_ id: String) async throws {
        let safe = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_"))) ?? id
        _ = try await send("DELETE", "v1/connections/\(safe)")
    }

    /// Deletes this install's Composio user and cached state (Remove everything / Uninstall), then the local ID.
    /// Without a stored ID there is nothing to forget and no request is made.
    public func forget() async throws {
        guard installID.existing != nil else { return }
        _ = try await send("POST", "v1/forget")
        installID.delete()
    }

    // MARK: Transport

    func send(_ method: String, _ path: String, body: Data? = nil, auth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: baseURL.appending(path: path))
        r.httpMethod = method
        r.timeoutInterval = 30
        if auth { for (k, v) in try headers() { r.setValue(v, forHTTPHeaderField: k) } }
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (d, resp) = try await session().data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw AntiChatError(.toolFailed, detail: "relay: no HTTP response") }
        if (200..<300).contains(http.statusCode) { return (d, http) }
        throw Self.error(status: http.statusCode, body: d, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
    }

    /// A relay error answer as the app's error (copy key = the relay code).
    public static func error(status: Int, body: Data, retryAfter: String? = nil) -> AntiChatError {
        let raw = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["code"] as? String ?? ""
        var code = raw.hasPrefix("relay.") ? String(raw.dropFirst(6)) : ""
        if !codes.contains(code) {
            switch status {
            case 429: code = "rateLimited"
            case 426: code = "updateRequired"
            case 503: code = "overCapacity"
            default: return AntiChatError(.toolFailed, detail: "relay HTTP \(status)")
            }
        }
        let recovery: [RecoveryAction] = switch code {
        case "rateLimited": [.retry]
        case "updateRequired": [.updateApp]
        default: []
        }
        return AntiChatError(domain: .relay, code: code, userMessageKey: "relay.\(code)", recovery: recovery,
                             detail: retryAfter.map { "retry-after \($0)" })
    }
}
