// AT-297 (R-297 AC1): for each of the 9 categories, disabling it makes a request through the gate fail in-process
// with `network.blockedByOfflineOnly` and reach nobody (0 server hits); enabling it lets the same request through.
// Each test binds its sessions to a private NetworkPolicyStore (request `ac.policy` tag), so the app's shared
// policy and other suites running in parallel are never touched.
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatNetwork

func privatePolicy() -> NetworkPolicyStore {
    NetworkPolicyStore(defaults: .inMemory())
}

@Suite("CategoryRefusalTests") struct CategoryRefusalTests {
    @Test(arguments: NetworkCategory.allCases)
    func disabledCategoryIsRefusedInProcess(_ category: NetworkCategory) async throws {
        let server = try TestHTTPServer()
        let policy = privatePolicy()
        let gated = NetworkGate.gated(category, policy: policy)
        let url = server.baseURL.appendingPathComponent(category.rawValue)

        policy.setEnabled(category, false)
        await #expect(throws: AntiChatError.self) { _ = try await gated.data(from: url) }
        do { _ = try await gated.data(from: url) } catch let e as AntiChatError {
            #expect(e.fullCode == "network.blockedByOfflineOnly" && e.userMessageKey == "network.blockedByOfflineOnly")
        }
        #expect(server.hits.isEmpty, "\(category): a blocked request reached the server")

        policy.setEnabled(category, true)
        let (data, response) = try await gated.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && data == server.body)
        #expect(server.hits.count == 1)
        print("AT-297 \(category.rawValue): blocked=yes hits-while-blocked=0 enabled=200")
    }

    /// A request the user's own action asked for (the list of apps when Settings › Connections opens) passes a
    /// category that is off by default; Offline only still refuses it; an unmarked request stays refused.
    @Test func aUserOpenedRequestPassesACategoryThatIsOffButNotOfflineOnly() async throws {
        let server = try TestHTTPServer()
        let policy = privatePolicy()
        let gated = NetworkGate.gated(.relay, policy: policy)
        let request = URLRequest(url: server.baseURL.appendingPathComponent("toolkits"))
        #expect(!policy.isEnabled(.relay))  // off until an app is connected
        await #expect(throws: AntiChatError.self) { _ = try await gated.data(for: request) }
        #expect(server.hits.isEmpty)
        let (_, response) = try await gated.data(for: NetworkGate.userOpened(request))
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && server.hits.count == 1)
        #expect(!policy.storedValue(.relay))  // the category itself stays off
        policy.offlineOnly = true
        await #expect(throws: AntiChatError.self) { _ = try await gated.data(for: NetworkGate.userOpened(request)) }
        #expect(server.hits.count == 1)
    }

    @Test func offlineOnlyRefusesEveryCategoryAndRestores() async throws {
        let server = try TestHTTPServer()
        let policy = privatePolicy()
        policy.setEnabled(.mcp, true)
        policy.offlineOnly = true
        for c in NetworkCategory.allCases {
            #expect(!policy.isEnabled(c))
            await #expect(throws: AntiChatError.self) { _ = try await NetworkGate.gated(c, policy: policy).data(from: server.baseURL) }
        }
        #expect(server.hits.isEmpty)
        policy.offlineOnly = false
        #expect(policy.isEnabled(.mcp) && !policy.isEnabled(.relay) && policy.isEnabled(.models))
    }

    @Test func rawSessionUseIsTaggedBySessionCategory() async throws {
        // A dependency that uses the URLSession directly (no GatedSession) is still blocked: the session's protocol
        // class carries its category. Uses the app's shared policy on a category nothing else in the suite enables.
        let server = try TestHTTPServer()
        #expect(!NetworkPolicyStore.shared.isEnabled(.crashReport))
        let s = NetworkGate.session(for: .crashReport)
        await #expect(throws: (any Error).self) { _ = try await s.data(from: server.baseURL) }
        #expect(server.hits.isEmpty)
    }

    /// M7.T15 (M7 rule 5, architecture §5.1): a request an incognito session makes that the gate refuses is reported
    /// as incognito, so it writes no `network_activity` row (it used to be reported as a normal request).
    @Test func incognitoRefusalWritesNoActivityRow() async throws {
        #expect(!NetworkPolicyStore.shared.isEnabled(.crashReport))
        let host = "incognito-\(UUID().uuidString.lowercased()).invalid"
        let seen = Mutex<[NetworkEvent]>([])
        let id = NetworkGate.addObserver { e in if e.host == host { seen.withLock { $0.append(e) } } }
        defer { NetworkGate.removeObserver(id) }
        let s = NetworkGate.incognitoSession(for: .crashReport)
        defer { s.invalidateAndCancel() }
        await #expect(throws: (any Error).self) { _ = try await s.data(from: URL(string: "https://\(host)/x")!) }
        let events = seen.withLock { $0 }
        #expect(events.count == 1 && events.allSatisfy { $0.outcome == .blocked && $0.incognito })
        #expect(events.allSatisfy { !NetworkGate.recordsActivity(incognito: $0.incognito) })
    }

    @Test func hostTable() {
        #expect(HostCategoryTable.lookup("huggingface.co") == .models)
        #expect(HostCategoryTable.lookup("cdn-lfs-us-1.hf.co") == .models)
        #expect(HostCategoryTable.lookup("cas-bridge.xethub.hf.co") == .models)
        #expect(HostCategoryTable.lookup("antichat.app") == .catalog)
        #expect(HostCategoryTable.lookup("example.com") == .other)
        #expect(HostCategoryTable.lookup(nil) == .other)
    }
}
