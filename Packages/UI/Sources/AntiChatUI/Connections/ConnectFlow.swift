// The one Composio connect flow of the app, shared by every place that offers [Connect] (the in-chat Connect card;
// Settings › Connections can use it too): `connect` → the Composio connection and its relay session (first use) → the
// hosted sign-in page in the browser → polling until the app is linked. State is per toolkit and observable, so two
// views of the same app (a card in the chat, a tile in Settings) agree. No sheet: a caller that wants to say on first
// use that connections run through Composio reads `isFirstUse` and shows its own line.
import AntiChatFoundation
import AntiChatHarness
import AntiChatTools
import Foundation
import Observation

@MainActor
@Observable
final class ConnectFlow {
    static let shared = ConnectFlow()

    enum Phase: Equatable, Sendable {
        case idle
        /// Creating the connection / fetching the sign-in link.
        case starting
        /// The browser is open; waiting for the sign-in to finish.
        case waiting
        case connected
        /// A copy key: `relay.*` for a relay refusal, `conn.unavailable` for an app the relay does not link yet,
        /// else `connect.card.failed`.
        case failed(String)
    }

    /// Toolkit → connection id, for the linked apps (as of the last `refresh` / `connect`).
    private(set) var linked: [String: String] = [:]
    /// The toolkits the relay offers (the default list until it answered).
    private(set) var offered: [String] = ComposioApps.defaults
    /// The relay links any catalogue app, not only `offered` (false until it said so).
    private(set) var linksAll = false
    private var phases: [String: Phase] = [:]
    @ObservationIgnored private var refreshedAt: ContinuousClock.Instant?
    @ObservationIgnored private let host: () -> MCPHost?
    @ObservationIgnored private let open: @MainActor (URL) -> Void

    /// `linked` / `phases`: a fixed state to draw (snapshots).
    init(host: @escaping () -> MCPHost? = { MCPTools.host }, open: @escaping @MainActor (URL) -> Void = { SiteLinks.open($0) },
         linked: [String: String] = [:], phases: [String: Phase] = [:]) {
        self.host = host
        self.open = open
        self.linked = linked
        self.phases = phases
    }

    /// This build has a relay (else there is nothing to connect through).
    var isAvailable: Bool { RelayClient.isAvailable() }

    private var connection: ComposioConnection? { isAvailable ? host().map { ComposioConnection(host: $0) } : nil }

    /// No Composio connection exists yet: the next `connect` creates it (the moment to say what Composio is).
    var isFirstUse: Bool {
        let rows = (try? host()?.repository.servers()) ?? []
        return !rows.contains { $0.kind == .composio }
    }

    func phase(_ toolkit: String) -> Phase {
        linked[toolkit] != nil ? .connected : phases[toolkit] ?? .idle
    }

    /// Re-reads the linked apps from the relay unless that was done within `maxAge`. Does nothing before the first
    /// use (no install ID, no request).
    func refresh(maxAge: Duration = .zero) async {
        if let at = refreshedAt, ContinuousClock.now - at < maxAge { return }
        guard !isFirstUse, let c = connection, let r = try? await c.connections() else { return }
        refreshedAt = .now
        let list = r.toolkits.filter { $0 != "*" }
        offered = list.isEmpty ? ComposioApps.defaults : list
        linksAll = r.linksAll
        linked = Dictionary(r.connections.filter(\.isActive).map { ($0.toolkit, $0.id) }, uniquingKeysWith: { a, _ in a })
    }

    /// [Connect]: opens the app's sign-in page and waits until it is linked (true) or it failed / timed out (false;
    /// `phase` then says why). A second call for a toolkit that is already connecting returns false at once.
    @discardableResult
    func connect(_ toolkit: String) async -> Bool {
        let now = phase(toolkit)
        if now == .connected { return true }
        guard now != .starting, now != .waiting else { return false }
        guard let c = connection else { phases[toolkit] = .failed(Self.genericFailure); return false }
        // A relay that answered and links only its own list: say so without a request (before its first answer the
        // relay's refusal of the link says the same, RelayClient.link).
        if refreshedAt != nil, !linksAll, !offered.contains(toolkit) { phases[toolkit] = .failed(Self.unavailable); return false }
        phases[toolkit] = .starting
        do {
            open(try await c.begin(toolkit: toolkit))
            phases[toolkit] = .waiting
            let ok = try await c.waitConnected(toolkit: toolkit)
            if ok { await refresh() }
            phases[toolkit] = ok ? .idle : .failed(Self.genericFailure)
            return ok && linked[toolkit] != nil
        } catch {
            phases[toolkit] = .failed(Self.failureKey(error))
            return false
        }
    }

    func disconnect(_ toolkit: String) async {
        guard let c = connection, let id = linked[toolkit] else { return }
        try? await c.disconnect(id)
        await refresh()
    }

    static let genericFailure = "connect.card.failed"
    static let unavailable = "conn.unavailable"

    /// The copy key for a failure: the relay's own sentence (`relay.rateLimited`, …) when it refused.
    static func failureKey(_ error: any Error) -> String {
        if let e = error as? AntiChatError, e.domain == .relay { return e.userMessageKey }
        return genericFailure
    }
}
