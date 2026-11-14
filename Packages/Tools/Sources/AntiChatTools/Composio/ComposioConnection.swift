// M7.T11 steps 3–4 (R-255 AC2–AC4): the Composio connect flow behind the Connections page, in at most three user
// steps — [Connect] on an app tile → the consent sheet's [Continue] → sign in in the browser. After consent:
// `MCPHost.addComposio` (relay session + the `composio` row over `<relay>/v1/mcp`, `.relay`), then the relay's hosted
// sign-in link for the toolkit; the page opens it and `waitConnected` polls `/v1/connections` every 2 s for up to
// 5 min until the toolkit is ACTIVE. No Composio account prompt in the app: Composio's own page does the sign-in.
import AntiChatFoundation
import Foundation

public struct ComposioConnection: Sendable {
    public let host: MCPHost
    public let relay: RelayClient
    let poll: Duration
    let timeout: Duration

    public init(host: MCPHost, relay: RelayClient = RelayClient(), poll: Duration = .seconds(2), timeout: Duration = .seconds(300)) {
        self.host = host; self.relay = relay; self.poll = poll; self.timeout = timeout
    }

    /// The apps the relay offers and their state (only once the user has used Connections: no install ID before).
    public func connections() async throws -> RelayConnections { try await relay.connections() }

    /// After consent: the Composio row exists and is connected, and the hosted sign-in URL for `toolkit` is returned.
    public func begin(toolkit: String) async throws -> URL {
        let row = try await host.addComposio(relay: relay)
        // Q-015 r7 (AT-255 c5-app): the row's session failed on the relay's own refusal (rate limit, over capacity,
        // update required): that is the answer to this Connect, not a sign-in link for a row that cannot be used.
        if row.state == .error, let code = row.errorCode, code.hasPrefix("relay.") {
            throw RelayClient.error(status: 0, body: Data(#"{"code":"\#(code)"}"#.utf8))
        }
        return try await relay.link(toolkit: toolkit)
    }

    /// Polls until `toolkit` is linked (true) or the time is up (false). Re-lists the row's tools on success.
    public func waitConnected(toolkit: String) async throws -> Bool {
        let clock = ContinuousClock(), end = clock.now + timeout
        while clock.now < end {
            try Task.checkCancellation()
            if try await relay.connections().connections.contains(where: { $0.toolkit == toolkit && $0.isActive }) {
                if let row = await host.composioServer() { await host.refreshTools(row.id) }
                return true
            }
            try await Task.sleep(for: poll)
        }
        return false
    }

    public func disconnect(_ id: String) async throws { try await relay.disconnect(id) }
}
