// Results of the M0 spike media lanes (voice M0.T05, image M0.T06, video M0.T07) that the helper still serves
// for the M0 benches. Kept apart from `EngineEvent` so the chat adapter contract stays exactly seven events;
// M3/M4/M5 replace these lanes with their own message groups (architecture §4.3 Voice / Media).
import Foundation

public enum MediaEvent: Codable, Sendable, Hashable {
    /// Result of a voice turn (M0.T05).
    case voiceReport(VoiceTurnReport)
    /// M0.T06: one sampling step finished (preview decoded for that step when requested).
    case imageProgress(ImageProgress)
    /// M0.T06: scheduler decisions around an image job (evict / keep / reload, with timings).
    case scheduler(SchedulerNote)
    /// M0.T06: the job ended (`completed` or `cancelled`).
    case imageResult(ImageResult)
    /// M0.T07: a video job changed stage or finished a sampler step.
    case videoProgress(VideoProgress)
    /// M0.T07: the video job ended (`completed`, `cancelled` or `failed`).
    case videoResult(VideoResult)
    /// M4.T04: a media job of the durable queue (`ClientMessage.mediaJob`); outputs only after the gate allowed them.
    case job(MediaJobEvent)
}
