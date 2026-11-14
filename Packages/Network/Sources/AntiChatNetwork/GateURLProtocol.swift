// M2.T02 step 3 (R-297 AC1; P-platform-08): the deny-mode URLProtocol carried by every gated session. It claims
// ONLY requests whose category is disabled and fails them at once with `network.blockedByOfflineOnly`; allowed
// traffic is never claimed, so it is never proxied. Category = the request's `ac.category` tag ?? the session's
// category (one subclass per category, so raw `URLSession` use by a dependency is tagged too) ?? host table.
import Foundation
import AntiChatFoundation

public class GateURLProtocol: URLProtocol, @unchecked Sendable {
    /// The session category this class stands for (`nil` = host table).
    class var sessionCategory: NetworkCategory? { nil }
    /// M7.T15 (architecture §5.1, M7 rule 5): the class of an incognito session; its refusals write no row either.
    class var incognitoSession: Bool { false }

    /// Request property keys (in-process only; URLProtocol properties never go on the wire).
    public static let categoryKey = "ac.category"
    public static let policyKey = "ac.policy"
    public static let turnKey = "ac.turn"

    static func category(of request: URLRequest, session: NetworkCategory?) -> NetworkCategory {
        if let tag = URLProtocol.property(forKey: categoryKey, in: request) as? String, let c = NetworkCategory(rawValue: tag) {
            return c
        }
        return session ?? HostCategoryTable.lookup(request.url?.host)
    }

    static func policy(of request: URLRequest) -> NetworkPolicyStore {
        (URLProtocol.property(forKey: policyKey, in: request) as? String).flatMap(NetworkPolicyStore.registry.store) ?? .shared
    }

    override public class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "ws" || scheme == "wss"
        else { return false }
        return !policy(of: request).isEnabled(category(of: request, session: sessionCategory))
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let category = Self.category(of: request, session: Self.sessionCategory)
        NetworkGate.emit(NetworkEvent(category: category, host: request.url?.host ?? "", bytes: 0, outcome: .blocked,
                                      turnID: URLProtocol.property(forKey: Self.turnKey, in: request) as? String,
                                      incognito: Self.incognitoSession))
        AppLog.log(.net, .info, "blocked \(category.rawValue) request to \(request.url?.host ?? "?")")
        client?.urlProtocol(self, didFailWithError: NetworkGate.blockedError(category))
    }

    override public func stopLoading() {}
}

// One subclass per category: the session's protocol class is its category tag.
final class GateUpdates: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .updates } }
final class GateCatalog: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .catalog } }
final class GateModels: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .models } }
final class GateSearch: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .search } }
final class GateConnectors: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .connectors } }
final class GateMCP: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .mcp } }
final class GateRelay: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .relay } }
final class GateCrashReport: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .crashReport } }
final class GateOther: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .other } }

// The incognito session of each category (NetworkGate.incognitoSession): same refusal, no `network_activity` row.
final class GateUpdatesIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .updates }; override class var incognitoSession: Bool { true } }
final class GateCatalogIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .catalog }; override class var incognitoSession: Bool { true } }
final class GateModelsIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .models }; override class var incognitoSession: Bool { true } }
final class GateSearchIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .search }; override class var incognitoSession: Bool { true } }
final class GateConnectorsIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .connectors }; override class var incognitoSession: Bool { true } }
final class GateMCPIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .mcp }; override class var incognitoSession: Bool { true } }
final class GateRelayIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .relay }; override class var incognitoSession: Bool { true } }
final class GateCrashReportIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .crashReport }; override class var incognitoSession: Bool { true } }
final class GateOtherIncognito: GateURLProtocol, @unchecked Sendable { override class var sessionCategory: NetworkCategory? { .other }; override class var incognitoSession: Bool { true } }

extension GateURLProtocol {
    static func protocolClass(for c: NetworkCategory, incognito: Bool) -> AnyClass {
        guard incognito else { return protocolClass(for: c) }
        switch c {
        case .updates: return GateUpdatesIncognito.self
        case .catalog: return GateCatalogIncognito.self
        case .models: return GateModelsIncognito.self
        case .search: return GateSearchIncognito.self
        case .connectors: return GateConnectorsIncognito.self
        case .mcp: return GateMCPIncognito.self
        case .relay: return GateRelayIncognito.self
        case .crashReport: return GateCrashReportIncognito.self
        case .other: return GateOtherIncognito.self
        }
    }

    static func protocolClass(for c: NetworkCategory) -> AnyClass {
        switch c {
        case .updates: GateUpdates.self
        case .catalog: GateCatalog.self
        case .models: GateModels.self
        case .search: GateSearch.self
        case .connectors: GateConnectors.self
        case .mcp: GateMCP.self
        case .relay: GateRelay.self
        case .crashReport: GateCrashReport.self
        case .other: GateOther.self
        }
    }
}
