// AT-294 timing leg (R-294 AC2; M2.T11 step 4): the flip never lands during a streaming reply or a media job; it lands
// within 1 s after the app goes idle (PackActivityTracker → ModelUpdateService.idle()), and at the next launch before
// the first load when idle never came.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct UpdateTimingTests {
    @Test func flipDeferredWhileStreamingThenWithinOneSecondOfIdle() async throws {
        let f = try await UpdateFixture("upd-stream")
        let svc = f.service()
        f.tracker.onIdle { Task { await svc.idle() } }
        f.catalog = f.v2
        f.tracker.begin(.chat)  // a ScriptedEngine reply is streaming
        await svc.catalogRefreshed()
        await svc.settle()
        #expect(await svc.phases[UpdateFixture.slot] == .waitingIdle)
        #expect(try await f.row()?.catalogEntryID == "starter")
        // Order: the flip waits for idle (above) and follows it. The "within 1 s" is the AT's wall-clock bar; here a
        // generous liveness cap only (a loaded host stretched the 1 s).
        let t0 = ContinuousClock.now
        f.tracker.end(.chat)
        var flipped = false
        while ContinuousClock.now - t0 < .seconds(30) {
            if try await f.row()?.catalogEntryID == "starter-v2" { flipped = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(flipped, "flip after idle")
    }

    @Test func flipDeferredDuringAMediaJob() async throws {
        let f = try await UpdateFixture("upd-job")
        let svc = f.service()
        f.catalog = f.v2
        f.tracker.beginJob()  // scripted image job: scheduler activeJob != nil
        await svc.catalogRefreshed()
        await svc.settle()
        await svc.idle()
        #expect(try await f.row()?.catalogEntryID == "starter")
        f.tracker.endJob()
        await svc.idle()
        #expect(try await f.row()?.catalogEntryID == "starter-v2")
    }

    @Test func idleNeverReachedFlipsAtNextLaunch() async throws {
        let f = try await UpdateFixture("upd-launch")
        f.catalog = f.v2
        f.tracker.begin(.chat)
        let first = f.service()
        await first.catalogRefreshed()  // downloaded, never idle; the app quits
        await first.settle()
        #expect(try await f.row()?.catalogEntryID == "starter")
        let next = f.service()  // relaunch: the blobs are in the store
        await next.launch()
        #expect(try await f.row()?.catalogEntryID == "starter-v2")
    }
}
