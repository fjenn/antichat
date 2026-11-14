import Foundation
import Testing
@testable import AntiChatNetwork

@Suite struct NetworkGateTests {
    @Test func sharedSessionIsStablePerCategory() {
        #expect(NetworkGate.session(for: .models) === NetworkGate.session(for: .models))
        #expect(NetworkGate.session(for: .models) !== NetworkGate.session(for: .search))
    }

    @Test func defaultConfigurationKeepsNoCookiesOrCache() {
        let c = NetworkGate.defaultConfiguration()
        #expect(c.httpCookieStorage == nil)
        #expect(c.httpShouldSetCookies == false)
        #expect(c.urlCredentialStorage == nil)
        #expect(c.urlCache == nil)
    }

    /// M1.T20 guard 6: incognito sessions keep nothing on disk and record no activity.
    @Test func incognitoConfigurationIsMemoryOnly() {
        let c = NetworkGate.incognitoConfiguration()
        #expect(c.urlCache?.diskCapacity == 0)
        #expect(c.httpCookieStorage == nil)
        #expect(c.urlCredentialStorage == nil)
        let s = NetworkGate.incognitoSession(for: .search)
        defer { s.invalidateAndCancel() }
        #expect(s.configuration.urlCache?.diskCapacity == 0)
        #expect(!NetworkGate.recordsActivity(incognito: true))
        #expect(NetworkGate.recordsActivity(incognito: false))
    }

    @Test func callerConfigurationIsKept() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForResource = 7
        let s = NetworkGate.session(for: .search, configuration: c, delegate: nil)
        defer { s.invalidateAndCancel() }
        #expect(s.configuration.timeoutIntervalForResource == 7)
    }
}
