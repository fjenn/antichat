// The Video pack is Ready only with its runtime on disk (VideoRuntimeInstall), a media call that made nothing never
// reads "Created a video / an image", and an `unavailable` video call shows a card that says so.
import AntiChatDesign
import AntiChatHarness
import Foundation
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct VideoRuntimeReadinessTests {
    @Test func readyNeedsTheRuntime() {
        let ready = PackRowState.ready(bytesOnDisk: 61_000_000_000)
        #expect(ready.withRuntime(.ready) == ready)
        #expect(ready.withRuntime(.missing(sizeBytes: 177)) == .notDownloaded(downloadBytes: 177, queued: false))
        #expect(ready.withRuntime(.installing(done: 50, total: 200)) == .downloading(percent: 25, paused: false, done: 50, total: 200))
        #expect(ready.withRuntime(.installing(done: 200, total: 200)) == .downloading(percent: 99, paused: false, done: 200, total: 200))
        #expect(ready.withRuntime(.failed) == .failed)
        #expect(PackRowState.updateAvailable(bytesOnDisk: 1).withRuntime(.missing(sizeBytes: 2)) == .notDownloaded(downloadBytes: 2, queued: false))
    }

    /// While the models are not here the row shows their state; the runtime never hides Off or a model download.
    @Test func otherStatesKeepTheirOwnLine() {
        let states: [PackRowState] = [.off(downloadBytes: 5), .notDownloaded(downloadBytes: 5, queued: true), .checking, .failed,
                                      .downloading(percent: 40, paused: false, done: 4, total: 10), .comingSoon]
        for s in states { #expect(s.withRuntime(.missing(sizeBytes: 177)) == s) }
    }

    @Test func createdOnlyForAFinishedResult() {
        func finished(_ tool: String, _ result: String?) -> Bool {
            ActivityLineView.mediaFinished(ToolActivity(id: "1", tool: tool, state: .done, result: result))
        }
        #expect(finished("create_video", VideoTurnPolicy.Outcome.done(videoID: "v1", path: "/x/v.mp4", poster: nil).resultJSON))
        #expect(finished("create_image", ImageTurnPolicy.Outcome.done(imageID: "a1", width: 8, height: 8, path: "/x/a.png").resultJSON))
        for bad in [#"{"status":"unavailable"}"#, #"{"status":"failed","error":"x"}"#, #"{"status":"not_shown"}"#, #"{"status":"not_started"}"#] {
            #expect(!finished("create_video", bad) && !finished("create_image", bad))
        }
        #expect(!finished("create_video", nil))
    }

    @Test func unavailableCallShowsItsCard() {
        let a = ToolActivity(id: "1", tool: "create_video", state: .done, result: #"{"status":"unavailable"}"#)
        let s = VideoJobActivity.settled(a, aspect: 16.0 / 9.0)
        #expect(s?.phase == .failed(code: VideoJobCardState.unavailableCode))
        #expect(s?.stageText == CopyKey("video.unavailable").string())
    }
}
}
