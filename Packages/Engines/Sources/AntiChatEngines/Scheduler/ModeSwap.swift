// M2.T15 step 1 (R-206 AC5, NFR-C7, R-210; P-shell-11). Normal ↔ Evil for chat: a chat keeps its
// `model_slot_snapshot` and mode; opening (or creating) a chat of a mode requests that mode's chat slot from the
// scheduler. Evil never uses `chat_fast` (the starter) and never gets a weaker stand-in (cross-task contract 7):
// with no Evil slot the request fails with `evil.notAvailablePack`. The warm / cold decision is WarmVariant's.
//   ModeSwap.slot(for:slots:)          the slot a new chat of `mode` runs on (pure)
//   ModeSwap.plan(resident:target:…)   warm hit / cold swap (which models unload) — for the AT-NFR-C7 record
//   ModeSwap(scheduler).newChat(mode:slots:)  ensureLoaded(role: .chat) of that slot → the lease
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

public enum ChatModeKind: String, Codable, Sendable, CaseIterable {
    case normal, evil
    public var other: ChatModeKind { self == .normal ? .evil : .normal }
}

/// The chat slots of the current selection (T06 `Selection`, mapped to ModelSlots by the app).
public struct ModeSlots: Sendable, Hashable {
    public var normal: ModelSlot?
    public var evil: ModelSlot?
    /// The starter (`chat_fast`, R-203): Normal only, until the selected model is ready.
    public var fastFirst: ModelSlot?
    public init(normal: ModelSlot?, evil: ModelSlot?, fastFirst: ModelSlot? = nil) {
        self.normal = normal; self.evil = evil; self.fastFirst = fastFirst
    }
}

public struct ModeSwap: Sendable {
    public let scheduler: ModelScheduler
    public init(scheduler: ModelScheduler) { self.scheduler = scheduler }

    public enum Plan: Sendable, Equatable {
        /// The target is resident already (warm second variant, or the same mode).
        case warm(String)
        /// The listed chat models unload, then the target loads (NFR-M1 + NFR-C1).
        case cold(unload: [String], load: String)
    }

    /// The slot a chat of `mode` runs on. `normalReady == false` lets a Normal chat use the starter (R-203); an
    /// Evil chat never does.
    public static func slot(for mode: ChatModeKind, slots: ModeSlots, normalReady: Bool = true) throws -> ModelSlot {
        switch mode {
        case .normal:
            if let n = slots.normal, normalReady { return n }
            if let f = slots.fastFirst { return f }
            if let n = slots.normal { return n }
            throw AntiChatError(domain: .model, code: "noModel", userMessageKey: "model.missing", detail: "no Normal chat slot")
        case .evil:
            guard let e = slots.evil, e.key != slots.fastFirst?.key, !e.key.hasPrefix("chat-0.8b") else {
                throw AntiChatError(domain: .model, code: "evilNotAvailable", userMessageKey: "evil.notAvailablePack",
                                    detail: "chat: no Evil slot on this Mac")
            }
            return e
        }
    }

    /// What opening `target` does given the resident set (E.2.7 + WarmVariant).
    public static func plan(resident: [ResidentEntry], target: ModelSlot, warm: Bool, budget: UInt64) -> Plan {
        if resident.contains(where: { $0.key == target.key }) { return .warm(target.key) }
        var unload = WarmVariant.swapVictims(entries: resident, incoming: target, role: .chat, warm: warm)
        if warm {
            let chats = resident.filter { $0.role == .chat || $0.role == .secondChat }
            let used = chats.reduce(UInt64(0)) { $0 + $1.bytes }
            if !WarmVariant.keepsWarm(currentBytes: target.footprintBytes, otherBytes: used, budget: budget) {
                unload = chats.filter { $0.refCount == 0 }.map(\.key).sorted()
            }
        }
        return .cold(unload: unload, load: target.key)
    }

    /// Opens a chat of `mode`: the scheduler makes that mode's slot resident (warm hit or cold swap) and leases it.
    public func newChat(mode: ChatModeKind, slots: ModeSlots, normalReady: Bool = true) async throws -> ModelLeaseToken {
        let s = try Self.slot(for: mode, slots: slots, normalReady: normalReady)
        return try await scheduler.ensureLoaded(role: .chat, model: s)
    }
}
