// M2.T13 step 2 (R-206 AC2, NFR-M3; R-236 pattern). What the chat shows around a media step-aside:
//   a media job's scheduler note "evicted" / "stepAside"  → `sched.makingRoom` "Making room for the {pack} model…"
//   the next user message reloads the chat model         → `status.loadingModel` (StatusLine, ReadinessQueue: the
//                                                            composer stays typeable, the queued message sends at .ready)
// Pure: the job card and the pending reply derive their line from the event stream.
import AntiChatEngineProtocol
import Foundation

public enum LoadingStatus: Sendable, Hashable {
    case none
    case makingRoom(pack: String)
    case loadingModel

    public var copyKey: String? {
        switch self {
        case .none: nil
        case .makingRoom: "sched.makingRoom"
        case .loadingModel: "status.loadingModel"
        }
    }

    public var args: [String: String] {
        if case .makingRoom(let p) = self { return ["pack": p] }
        return [:]
    }

    /// After a media event of a job for `pack` (Photo / Video): the step-aside line until the job's first progress.
    public static func next(_ s: LoadingStatus, media: MediaEvent, pack: String) -> LoadingStatus {
        switch media {
        case .scheduler(let n) where n.action == "evicted": .makingRoom(pack: pack)
        case .imageProgress, .imageResult, .videoResult: .none
        default: s
        }
    }

    /// After a lifecycle event of a chat turn.
    public static func next(_ s: LoadingStatus, lifecycle: LifecycleEvent) -> LoadingStatus {
        switch lifecycle {
        case .loadState(.loading): .loadingModel
        case .loadState(.ready), .loadState(.evicted): .none
        default: s
        }
    }
}
