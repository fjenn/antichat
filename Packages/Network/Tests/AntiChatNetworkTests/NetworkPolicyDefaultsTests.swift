// AT-209 AC3 (R-209): a fresh container's network defaults: updates, catalog, models, search on; connectors, mcp,
// relay off until a connection is added; crash reports off; Offline only off. `-OfflineOnly YES` forces it on;
// switching Offline only off restores every category's previous value. Plus PathStatus `-FakeNetwork`.
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatNetwork

@Suite("NetworkPolicyDefaultsTests") struct NetworkPolicyDefaultsTests {
    @Test func freshContainerDefaults() {
        let p = privatePolicy()
        #expect(!p.offlineOnly)
        for c in [NetworkCategory.updates, .catalog, .models, .search, .other] { #expect(p.isEnabled(c), "\(c)") }
        for c in [NetworkCategory.connectors, .mcp, .relay, .crashReport] { #expect(!p.isEnabled(c), "\(c)") }
        #expect(Set(p.enabledCategories) == [.updates, .catalog, .models, .search, .other])
    }

    /// Q-015 r2: a launch override reaches the store as a string ("NO"); it still switches the category off.
    @Test func stringOverrideIsRead() {
        let d = UserDefaults.inMemory()
        d.set("NO", forKey: NetworkPolicyStore.key(.search))
        #expect(NetworkPolicyStore(defaults: d).storedValue(.search) == false)
        d.set("YES", forKey: NetworkPolicyStore.key(.mcp))
        #expect(NetworkPolicyStore(defaults: d).storedValue(.mcp) == true)
    }

    @Test func launchOfflineOnlyAndRestore() {
        var o = LaunchOptions()
        o.offlineOnly = true
        let p = NetworkPolicyStore(defaults: UserDefaults.inMemory(), launch: o)
        #expect(p.offlineOnly && p.enabledCategories.isEmpty)
        p.setEnabled(.search, false)
        p.offlineOnly = false
        #expect(!p.isEnabled(.search) && p.isEnabled(.models))
    }

    /// The shared policy of a test process lives in a suite of its own, not in the test tool's `.standard` domain that
    /// every test process on the Mac shares (a concurrent run's Offline only showed in a Settings › Privacy snapshot).
    @Test func testProcessSharedPolicyIsPrivateToTheProcess() {
        #expect(NetworkPolicyStore.isTestProcess())
        #expect(NetworkPolicyStore.appDefaults() !== UserDefaults.standard)
        let key = NetworkPolicyStore.key(.relay)
        let before = UserDefaults.standard.object(forKey: key)
        let shared = NetworkPolicyStore.shared
        let was = shared.storedValue(.relay)
        shared.setEnabled(.relay, !was)
        defer { shared.setEnabled(.relay, was) }
        #expect(shared.storedValue(.relay) == !was)
        #expect((UserDefaults.standard.object(forKey: key) as? Bool) == (before as? Bool), "nothing reached the tool's domain")
    }

    @Test func fakeNetwork() {
        #expect(PathStatus(fake: "none").isOffline)
        #expect(PathStatus(fake: "expensive").state == .expensive)
        #expect(!PathStatus(fake: "ok").isOffline)
    }
}
