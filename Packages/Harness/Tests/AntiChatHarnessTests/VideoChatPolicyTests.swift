// M5.T03 step 4: chat during a video job — T2 waits with `video.gpuBusy` + [Pause video]; T3+ with chat resident answers.
import Testing
@testable import AntiChatHarness

@Suite struct VideoChatPolicyTests {
    @Test func truthTable() {
        #expect(VideoChatPolicy.decide(videoRunning: false, chatResident: false, lowTier: true) == .answer)
        #expect(VideoChatPolicy.decide(videoRunning: true, chatResident: false, lowTier: true) == .wait(notice: "video.gpuBusy", action: "video.pause"))
        #expect(VideoChatPolicy.decide(videoRunning: true, chatResident: true, lowTier: true) == .wait(notice: "video.gpuBusy", action: "video.pause"))
        #expect(VideoChatPolicy.decide(videoRunning: true, chatResident: true, lowTier: false) == .answer)
        #expect(VideoChatPolicy.decide(videoRunning: true, chatResident: false, lowTier: false) == .wait(notice: "video.gpuBusy", action: "video.pause"))
        #expect(VideoChatPolicy.pauseSequence == [.pauseVideo, .reloadChat, .answer, .resumeVideo])
    }
}
