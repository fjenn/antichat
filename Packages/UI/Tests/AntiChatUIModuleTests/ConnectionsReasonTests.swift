// M9.T08: the add-server sheet's failure line says what went wrong in one sentence (`conn.mcp.failed` {reason}),
// never the NSError dump with its userInfo.
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ConnectionsReasonTests {
    @Test func networkErrorIsTheSystemSentence() {
        let e = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://chat.example/mcp"])
        let r = ConnectionsModel.reason(e)
        #expect(r == e.localizedDescription)
        #expect(!r.contains("Error Domain") && !r.contains("UserInfo"))
    }

    @Test func otherErrorsKeepTheirDescription() {
        struct Odd: Error { let code = 7 }
        #expect(ConnectionsModel.reason(Odd()).contains("Odd"))
    }
}
