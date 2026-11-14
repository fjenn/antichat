// M7.T11 (R-255 AC2/AC3, DoD): the Composio row over the relay. After consent, `addComposio` turns `.relay` on, creates
// the relay session (first use → install ID), stores a `composio` row with no secret and connects through the relay
// transport with the §8.2 headers. The stub key (`relay.notConfigured`) leaves no row and `.relay` off.
import AntiChatFoundation
@testable import AntiChatNetwork
import AntiChatStorage
@testable import AntiChatTools
import Foundation
import MCP
import Testing

@Suite(.serialized) struct ComposioHostTests {
    final class Seen: @unchecked Sendable {
        let lock = NSLock()
        var urls: [URL] = []
        var headers: [String: String] = [:]
    }

    static let host = "127.0.0.2"

    static func env() throws -> (MCPHost, RelayClient, MemorySecrets, NetworkPolicyStore, Seen) {
        let db = try AppDatabase.inMemory()
        let secrets = MemorySecrets()
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        let seen = Seen()
        let host = MCPHost(database: db, secrets: secrets, makeTransport: { _, _, _, _ in
            Issue.record("a Composio row must use the relay transport")
            return ScriptedMCPTransport(jsonl: MCPHostTests.jsonl)
        }, policy: policy, makeRelayTransport: { url, headers in
            seen.lock.withLock { seen.urls.append(url); seen.headers = headers() }
            return ScriptedMCPTransport(jsonl: MCPHostTests.jsonl)
        })
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelayStub.self]
        let s = URLSession(configuration: cfg)
        let relay = RelayClient(baseURL: URL(string: "http://\(Self.host):3000")!, installID: InstallID(secrets: secrets),
                                session: { GatedSession(session: s, category: .relay, policy: policy) }, version: "1.0")
        return (host, relay, secrets, policy, seen)
    }

    @Test func addComposioStoresRelayRowAndConnects() async throws {
        let (host, relay, secrets, policy, seen) = try Self.env()
        RelayIdentityTests.reset(host: Self.host)
        #expect(!policy.storedValue(.relay))
        let row = try await host.addComposio(relay: relay)
        #expect(row.kind == .composio && row.authRef == nil && row.state == .connected)
        #expect(row.urlOrCmd == "http://127.0.0.2:3000/v1/mcp")
        #expect(policy.storedValue(.relay) && !policy.storedValue(.mcp))
        let id = try #require(InstallID(secrets: secrets).existing)
        #expect(seen.lock.withLock { seen.headers["X-AntiChat-Install"] } == id)
        #expect(secrets.all.count == 1)  // the install ID only: no Composio secret in the app
        let tools = try host.repository.tools(server: row.id)
        #expect(!tools.isEmpty)
        let ds = MCPToolProxy.descriptors(servers: try host.repository.servers(), tools: [row.id: tools], verified: { _ in false })
        #expect(ds.allSatisfy { $0.composio })
        // adding again re-uses the row
        #expect(try await host.addComposio(relay: relay).id == row.id)
        await host.remove(row.id)
        #expect(!policy.storedValue(.relay))
    }

    /// DoD: the stub key shows `relay.notConfigured`; no row, no retries, `.relay` back off.
    @Test func stubKeyLeavesNothing() async throws {
        let (host, relay, _, policy, seen) = try Self.env()
        RelayIdentityTests.reset((503, #"{"code":"relay.notConfigured"}"#, [:]), host: Self.host)
        do {
            _ = try await host.addComposio(relay: relay)
            Issue.record("expected relay.notConfigured")
        } catch let e as AntiChatError {
            #expect(e.userMessageKey == "relay.notConfigured")
        }
        #expect(try host.repository.servers().isEmpty)
        #expect(!policy.storedValue(.relay))
        #expect(seen.lock.withLock { seen.urls.isEmpty })
        #expect(RelayStub.seen(Self.host).count == 1)
    }

    /// AT-255 c5-app (Q-015 r7): the relay's 429 on /v1/mcp (`{code:"relay.rateLimited"}`) is the relay error, not
    /// "HTTP 429": the row keeps its copy key and [Connect] throws it (the page shows "Connections are busy"), no link.
    @Test func rateLimitedMCPEndpointSurfacesTheRelayCode() async throws {
        let (_, relay, secrets, policy, _) = try Self.env()
        RelayIdentityTests.reset(host: Self.host)
        let mcpHost = "127.0.0.3"
        RelayIdentityTests.reset((429, #"{"code":"relay.rateLimited"}"#, ["Retry-After": "30"]), host: mcpHost)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelayStub.self]
        let stubbed = URLSession(configuration: cfg)
        let host = MCPHost(database: try AppDatabase.inMemory(), secrets: secrets, policy: policy, makeRelayTransport: { _, headers in
            MCPHTTPTransport(endpoint: URL(string: "http://\(mcpHost):3000/v1/mcp")!, session: stubbed,
                             incognitoSession: { stubbed }, headers: headers, category: .relay)
        })
        let flow = ComposioConnection(host: host, relay: relay)
        do {
            _ = try await flow.begin(toolkit: "gmail")
            Issue.record("expected relay.rateLimited")
        } catch let e as AntiChatError {
            #expect(e.domain == .relay && e.userMessageKey == "relay.rateLimited")
        }
        let row = try #require(await host.composioServer())
        #expect(row.state == .error && row.errorCode == "relay.rateLimited")
        #expect(!RelayStub.seen(Self.host).contains { $0.path.hasSuffix("/link") })  // no sign-in link asked for
    }

    /// AT-255 c4 (mock leg, `ComposioE2EMockTests` in the card): the app ↔ `make relay-dev` (relay/.env.test) ↔ mock
    /// Composio. Consent → session + row → tools over the relay's /v1/mcp → Gmail link → the mock's sign-in page →
    /// ACTIVE → a Gmail search through COMPOSIO_MULTI_EXECUTE_TOOL. Runs when ANTICHAT_RELAY_URL is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_RELAY_URL"] != nil))
    func liveRelayDevEndToEnd() async throws {
        let base = try #require(URL(string: ProcessInfo.processInfo.environment["ANTICHAT_RELAY_URL"]!))
        let db = try AppDatabase.inMemory()
        let secrets = MemorySecrets()
        let policy = NetworkPolicyStore(defaults: UserDefaults.inMemory())
        let plain = URLSession(configuration: .ephemeral)
        let host = MCPHost(database: db, secrets: secrets, policy: policy, makeRelayTransport: { url, headers in
            MCPHTTPTransport(endpoint: url, session: plain, incognitoSession: { plain }, headers: headers, category: .relay)
        })
        let relay = RelayClient(baseURL: base, installID: InstallID(secrets: secrets),
                                session: { GatedSession(session: plain, category: .relay, policy: policy) })
        let flow = ComposioConnection(host: host, relay: relay, poll: .milliseconds(200), timeout: .seconds(20))
        let link = try await flow.begin(toolkit: "gmail")
        let row = try #require(await host.composioServer())
        #expect(row.state == .connected)
        let names = try host.repository.tools(server: row.id).map(\.name)
        #expect(names.contains(SlugPermission.multiExecute) && names.contains(SlugPermission.searchTools))
        _ = try await plain.data(from: link)  // the browser step: the mock's hosted sign-in marks the account ACTIVE
        #expect(try await flow.waitConnected(toolkit: "gmail"))
        let args = #"{"tools":[{"tool_slug":"GMAIL_FETCH_EMAILS","arguments":{"query":"invoice","max_results":5}}],"thought":"search","sync_response_to_workbench":false}"#
        #expect(SlugPermission.slugs(argumentsJSON: args) == ["GMAIL_FETCH_EMAILS"])
        let r = try await host.call(server: row.id, tool: SlugPermission.multiExecute, argumentsJSON: args)
        #expect(!r.isError && !r.text.isEmpty)
    }
}
