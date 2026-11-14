// M2.T20 (R-201 AC5, R-203; S-04): what onboarding step 4, the starter label and the ModeSwitch show while the first-run
// install runs. Pure over the plan items, the coordinator's jobs, the store and the install views, so every row state is
// unit-testable:
//   row per chosen pack (+ the Evil row): waiting (nothing of it queued yet) → n % → Checking (verifying) → Ready (every
//   model of it has its install view); paused (system: no internet) and failed (Retry) win over downloading;
//   starter = the `chat_fast` item's view exists (Open chat's moment, NFR-M5); tier = the pack's `chat` model's view.
import Foundation

public struct SetupProgress: Sendable, Equatable {
    public enum RowState: Sendable, Equatable {
        case waiting
        case downloading(percent: Int)
        case checking
        case ready
        case paused
        case failed
    }

    public struct Row: Sendable, Equatable, Identifiable {
        /// `chat`, `voice`, `photo`, `video` or `evil`.
        public var group: String
        public var id: String { group }
        public var state: RowState
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public init(group: String, state: RowState, bytesDone: Int64, bytesTotal: Int64) {
            self.group = group; self.state = state; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal
        }
    }

    public init(rows: [Row], starterReady: Bool, tierReady: Bool, tierPercent: Int, starterFraction: Double, evilRemainingBytes: Int64,
                evilVerifying: Bool) {
        self.rows = rows; self.starterReady = starterReady; self.tierReady = tierReady; self.tierPercent = tierPercent
        self.starterFraction = starterFraction; self.evilRemainingBytes = evilRemainingBytes; self.evilVerifying = evilVerifying
    }

    public var rows: [Row]
    public var starterReady: Bool
    /// The tier chat model's view exists (the hand-off target).
    public var tierReady: Bool
    /// 0…100 of the tier chat model's own files (the `starter.quick` %).
    public var tierPercent: Int
    /// 0…1 of the starter's files (R-299 "Sending when Chat is ready (NN%)").
    public var starterFraction: Double
    /// Bytes of the Evil items still to fetch (EvilReadiness).
    public var evilRemainingBytes: Int64
    public var evilVerifying: Bool

    public var readyCount: Int { rows.filter { $0.state == .ready }.count }

    public static let empty = SetupProgress(rows: [], starterReady: false, tierReady: false, tierPercent: 0, starterFraction: 0,
                                            evilRemainingBytes: 0, evilVerifying: false)

    /// - Parameters:
    ///   - normal: the Normal plan's items (step 2); `evil`: the Evil items (step 3, empty when off).
    ///   - jobs: the coordinator's jobs now; `present`: sha256 in the store; `installed`: model ids with an install view.
    ///   - preparing: groups whose files are installed but whose install-time step still runs (the Photo/Video
    ///     ChildSafetyCheck compile, M4): their row stays `checking` until it ends.
    public static func compute(normal: [InstallPlan.Item], evil: [InstallPlan.Item], jobs: [DownloadJob],
                               present: (String) -> Bool, installed: Set<String>, preparing: Set<String> = []) -> SetupProgress {
        let bySHA = Dictionary(jobs.filter { $0.state != .cancelled }.map { ($0.sha256, $0) }, uniquingKeysWith: { a, _ in a })

        func bytes(_ reqs: [DownloadRequest]) -> (Int64, Int64) {
            reqs.reduce((Int64(0), Int64(0))) { acc, r in
                let done: Int64 = present(r.sha256) ? r.size : min(r.size, bySHA[r.sha256]?.bytesDone ?? 0)
                return (acc.0 + done, acc.1 + r.size)
            }
        }

        func row(_ group: String, _ its: [InstallPlan.Item]) -> Row {
            let reqs = its.flatMap(\.requests)
            let (done, total) = bytes(reqs)
            let js = reqs.compactMap { present($0.sha256) ? nil : bySHA[$0.sha256] }
            let state: RowState
            if its.allSatisfy({ installed.contains($0.modelID) }) {
                state = preparing.contains(group) ? .checking : .ready
            } else if js.contains(where: { $0.state == .failed }) {
                state = .failed
            } else if js.contains(where: { $0.state == .paused && $0.pauseReason != .user }), !js.contains(where: { $0.state == .running }) {
                state = .paused
            } else if done >= total {
                state = .checking  // every byte is in; verification / the install view is next
            } else if done == 0, !js.contains(where: { $0.state == .running || $0.state == .verifying }) {
                state = .waiting
            } else {
                state = .downloading(percent: min(99, Int((Double(done) / Double(max(1, total)) * 100).rounded(.down))))
            }
            return Row(group: group, state: state, bytesDone: done, bytesTotal: total)
        }

        var rows: [Row] = []
        for pack in ModelPack.allCases {
            let its = normal.filter { $0.pack == pack }
            if !its.isEmpty { rows.append(row(pack.rawValue, its)) }
        }
        if !evil.isEmpty { rows.append(row("evil", evil)) }

        let starter = normal.filter { $0.role == "chat_fast" }
        let tier = normal.filter { $0.pack == .chat && $0.role == "chat" }
        let (sDone, sTotal) = bytes(starter.flatMap(\.requests))
        let (tDone, tTotal) = bytes(tier.flatMap(\.requests))
        let (eDone, eTotal) = bytes(evil.flatMap(\.requests))
        let evilJobs = evil.flatMap(\.requests).compactMap { bySHA[$0.sha256] }
        return SetupProgress(
            rows: rows,
            starterReady: !starter.isEmpty && starter.allSatisfy { installed.contains($0.modelID) },
            tierReady: !tier.isEmpty && tier.allSatisfy { installed.contains($0.modelID) },
            tierPercent: tTotal > 0 ? min(tier.allSatisfy { installed.contains($0.modelID) } ? 100 : 99, Int(Double(tDone) / Double(tTotal) * 100)) : 100,
            starterFraction: sTotal > 0 ? Double(sDone) / Double(sTotal) : 1,
            evilRemainingBytes: max(0, eTotal - eDone),
            evilVerifying: evilJobs.contains { $0.state == .verifying } || (eTotal > 0 && eDone >= eTotal && !evil.allSatisfy { installed.contains($0.modelID) }))
    }
}
