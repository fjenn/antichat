// M5.T03 step 4 (VISION §2.16 "underneath 5"; R-040): chat while a video job runs. On T2 the chat model stepped aside
// for the video model (they do not fit B together), so a new message does not reload it mid-job: it waits, queued,
// with the notice `video.gpuBusy` and a [Pause video] action (`video.pause`). Pause → the job pauses between steps
// (the runtime's /pause), the chat model reloads, the turn is answered, then the video resumes. On T3+ chat stays
// resident beside the job and answers at once. Pure decision type; the turn controller / job card call it (M5.T11).
import Foundation

public enum VideoChatPolicy {
    public enum Decision: Sendable, Equatable {
        /// Answer now (no video job, or chat is resident beside it).
        case answer
        /// Queue the message; show `notice` with the `action` button that pauses the video for this turn.
        case wait(notice: String, action: String)
    }

    public static let noticeKey = "video.gpuBusy"
    public static let actionKey = "video.pause"

    /// `videoRunning`: a video job holds the GPU now. `chatResident`: the scheduler kept the chat model beside it
    /// (T3+ when chat + video fit B). `lowTier`: T0–T2.
    public static func decide(videoRunning: Bool, chatResident: Bool, lowTier: Bool) -> Decision {
        guard videoRunning else { return .answer }
        if chatResident && !lowTier { return .answer }
        return .wait(notice: noticeKey, action: actionKey)
    }

    /// The steps of [Pause video] for one queued turn, in order.
    public enum Step: String, Sendable, CaseIterable { case pauseVideo, reloadChat, answer, resumeVideo }
    public static let pauseSequence: [Step] = Step.allCases
}
