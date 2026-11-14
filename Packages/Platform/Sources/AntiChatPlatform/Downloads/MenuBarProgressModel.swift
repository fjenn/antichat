// M2.T09 step 8 (R-204 AC2, menu-bar part): the observable model the M8 menu bar item binds to — the active pack's
// progress, the overall fraction and ETA, and whether anything is downloading. Fed by `ProgressAggregator`.
import Foundation
import Observation

@MainActor @Observable
public final class MenuBarProgressModel {
    public private(set) var packs: [PackProgress] = []

    /// M8.T12: a pack's download finished (it reached `.done` in this launch; the notification's "{pack} is ready").
    @ObservationIgnored public var onPackFinished: (@MainActor (String) -> Void)?

    public init() {}

    /// Called with each aggregator snapshot (hop to the main actor first).
    public func update(_ snapshot: [PackProgress]) {
        let before = Dictionary(packs.map { ($0.pack, $0.state) }, uniquingKeysWith: { a, _ in a })
        packs = snapshot
        for p in snapshot where p.state == .done {
            if let was = before[p.pack], was != .done { onPackFinished?(p.pack) }
        }
    }

    /// Something is downloading or verifying.
    public var isActive: Bool { packs.contains { $0.state == .downloading || $0.state == .verifying } }
    /// The pack the menu bar names: the first one still in progress, else the first paused or failed.
    public var current: PackProgress? {
        packs.first { $0.state == .downloading || $0.state == .verifying } ?? packs.first { $0.state == .failed || $0.state == .paused }
    }
    public var overallFraction: Double {
        let total = packs.reduce(Int64(0)) { $0 + $1.bytesTotal }
        return total > 0 ? Double(packs.reduce(Int64(0)) { $0 + $1.bytesDone }) / Double(total) : 0
    }
    /// The longest remaining pack ETA (the queue finishes when the last pack does).
    public var etaSeconds: Double? { packs.compactMap(\.etaSeconds).max() }

    /// Binds to `aggregator` (main-actor delivery).
    public func bind(_ aggregator: ProgressAggregator) {
        update(aggregator.snapshot)
        aggregator.observe { [weak self] s in Task { @MainActor in self?.update(s) } }
    }
}
