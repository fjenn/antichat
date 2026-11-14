// M2.T09 step 2 (R-204 AC6, E.2.5; VISION §2.19): what the network path allows. No route → the queue waits
// (`download.offline`, it continues by itself); Low Data Mode (`isConstrained`) → the queue waits with the same
// notice; a metered link (`isExpensive`, e.g. a personal hotspot) and more than 1 GB to fetch → ask first
// (`download.expensiveAsk`: [Download] [Later]). Known limitation: the system flag only — a hotspot macOS does not
// mark as expensive is not detected (M2.T09 known failure mode, minor).
import AntiChatNetwork
import Foundation

public enum PathPolicy {
    public static let askAboveBytes: Int64 = 1_000_000_000

    public enum Decision: Sendable, Equatable {
        case proceed
        /// Hold the queue; resume on the next satisfied, unconstrained path.
        case wait(noticeKey: String)
        /// Ask before starting (`download.expensiveAsk`).
        case ask
    }

    public static func decide(_ state: PathStatus.State, pendingBytes: Int64, approvedExpensive: Bool = false) -> Decision {
        switch state {
        case .none, .constrained: .wait(noticeKey: "download.offline")
        case .expensive where pendingBytes > askAboveBytes && !approvedExpensive: .ask
        case .expensive, .ok: .proceed
        }
    }
}
