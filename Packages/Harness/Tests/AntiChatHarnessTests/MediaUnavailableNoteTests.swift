// A media call that could not start tells the model so in plain words (it writes the reply's sentence on T3+).
import Foundation
import Testing
@testable import AntiChatHarness

@Suite struct MediaUnavailableNoteTests {
    @Test func unavailableCarriesANote() {
        for tool in ["create_video", "create_image"] {
            let seen = MediaToolResult.forModel(name: tool, result: #"{"status":"unavailable"}"#)
            #expect(seen.contains(#""status":"unavailable""#) && seen.contains("Nothing was created") && seen.contains("Settings > Capabilities"))
        }
        #expect(MediaToolResult.forModel(name: "web_search", result: #"{"status":"unavailable"}"#) == #"{"status":"unavailable"}"#)
        #expect(MediaToolResult.forModel(name: "create_video", result: #"{"status":"not_started"}"#) == #"{"status":"not_started"}"#)
    }
}
