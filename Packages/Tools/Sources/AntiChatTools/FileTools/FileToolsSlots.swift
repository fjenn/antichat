// A-M6-T21a (a), M6.T21 close review #5 (lead ruling (c)): per-chat isolation through File tools service SLOTS.
// The app embeds `FileToolsProtocol.maxSlots` identical services per variant, each under its own bundle id and so in
// its own App Sandbox container: code running in one slot cannot open another slot's files (kernel, plus the sbpl
// deny rules every slot carries). This actor leases a slot to ONE chat at a time:
//   - a chat that holds a slot keeps it (its interpreter and globals survive between runs);
//   - a chat without one gets an idle slot: a never-used one first, else the least recently used;
//   - before a slot serves a chat other than its last holder, every variant the slot served is WIPED (the service ends
//     every interpreter, deletes every jail and reports its scratch folder empty; anything else fails the lease);
//   - when all `capacity` slots are running code, the chat WAITS (FIFO) and its tool call shows "waiting for a free
//     sandbox" (`sandbox.waiting`) until a slot is idle. This is a capacity limit, never an isolation exception.
// Capacity per tier (FileToolsTools.slotCount): T0 2 (1 GB cap each), T1 2, T2+ 3 (2 GB cap each); the reasoning is
// in A-M6-T21a.
import AntiChatEngineProtocol
import Foundation
import Synchronization

public actor FileToolsSlots {
    /// The app's leaser over the shipped slot ids.
    public static let shared = FileToolsSlots(capacity: 2)

    /// Wipes slot `slot` of the variant (`network`); `previous` is the chat that last held it. Returns
    /// `ResetAck.scratchEmpty`.
    public typealias Wiper = @Sendable (_ slot: Int, _ network: Bool, _ previous: String?) async throws -> Bool

    public struct Lease: Sendable, Equatable {
        public let slot: Int
        public let chatID: String
        public let network: Bool
    }

    public enum SlotError: Error, Equatable, Sendable {
        /// The slot's wipe failed or its scratch folder was not empty afterwards: it is never handed to another chat.
        case wipeFailed(slot: Int, String)
    }

    struct Slot {
        var holder: String?
        var busy = 0
        var lastUsed: ContinuousClock.Instant?
        /// Variants (network on/off) that served `holder` since the last wipe (a lease move wipes each of them).
        var used: Set<Bool> = []
        /// Set from a holder change until a wipe proved the slot empty (and when a wipe failed).
        var dirty = false
        /// The wipe in progress (a second call of the same chat waits for it instead of wiping again).
        var prep: Task<Void, Error>?
    }

    struct Waiter {
        let id: UUID
        let chatID: String
        let continuation: CheckedContinuation<Int, Error>
    }

    public let prefix: String
    public private(set) var capacity: Int
    private var slots: [Slot]
    private var waiters: [Waiter] = []
    private let wiper: Wiper?

    public init(capacity: Int, prefix: String = FileToolsProtocol.servicePrefix, wiper: Wiper? = nil) {
        self.prefix = prefix
        self.capacity = min(max(1, capacity), FileToolsProtocol.maxSlots)
        self.slots = Array(repeating: Slot(), count: FileToolsProtocol.maxSlots)
        self.wiper = wiper
    }

    /// Sets how many slots run code at once (1…maxSlots). Slots above the new capacity get no new chats.
    public func configure(capacity: Int) {
        self.capacity = min(max(1, capacity), FileToolsProtocol.maxSlots)
        serveWaiters()
    }

    // MARK: Leases

    /// The slot `chatID` runs in; waits while every slot is running another chat's code. `waitKey` (the tool call id,
    /// else the chat id) is listed in `waiting` while it waits.
    public func acquire(chatID: String, network: Bool, waitKey: String? = nil) async throws -> Lease {
        let slot: Int
        if let k = slots.indices.first(where: { slots[$0].holder == chatID }) {
            slots[k].busy += 1
            slot = k
        } else if let k = idleSlot() {
            take(k, for: chatID)
            slot = k
        } else {
            let id = UUID()
            let key = waitKey ?? chatID
            Self.setWaiting(key, true)
            defer { Self.setWaiting(key, false) }
            slot = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    waiters.append(Waiter(id: id, chatID: chatID, continuation: cont))
                }
            } onCancel: {
                Task { await self.cancelWaiter(id) }
            }
        }
        do {
            try await prepare(slot, for: chatID, network: network)
        } catch {
            slots[slot].busy -= 1
            serveWaiters()
            throw error
        }
        return Lease(slot: slot + 1, chatID: chatID, network: network)
    }

    /// Ends a lease's call (the chat keeps the slot until another chat needs it).
    public func release(_ lease: Lease) {
        let k = lease.slot - 1
        guard slots.indices.contains(k), slots[k].busy > 0 else { return }
        slots[k].busy -= 1
        slots[k].lastUsed = .now
        serveWaiters()
    }

    /// The slot and the variants `chatID` used, if it holds one (reset, chat deleted).
    public func holding(_ chatID: String) -> (slot: Int, variants: [Bool])? {
        guard let k = slots.indices.first(where: { slots[$0].holder == chatID }) else { return nil }
        return (k + 1, slots[k].used.sorted { !$0 && $1 })
    }

    /// Chat deleted, bulk delete, Evil wipe, incognito end: the slot no longer belongs to the chat (its files are
    /// deleted by the caller's reset; the next holder's wipe covers every variant the slot served).
    public func forget(_ chatID: String) {
        for k in slots.indices where slots[k].holder == chatID && slots[k].busy == 0 { slots[k].holder = nil }
    }

    /// Test and diagnostics view: (holder, busy) per slot up to the capacity.
    public func snapshot() -> [(holder: String?, busy: Int)] { slots.prefix(capacity).map { ($0.holder, $0.busy) } }

    private func idleSlot() -> Int? {
        let idle = (0..<capacity).filter { slots[$0].busy == 0 }
        if let fresh = idle.first(where: { slots[$0].holder == nil && slots[$0].used.isEmpty }) { return fresh }
        if let free = idle.first(where: { slots[$0].holder == nil }) { return free }
        return idle.min { (slots[$0].lastUsed ?? .now) < (slots[$1].lastUsed ?? .now) }
    }

    /// Reserves slot `k` for `chatID` (busy = 1). A new holder starts with nothing it may keep: `prepare` wipes.
    private func take(_ k: Int, for chatID: String) {
        if slots[k].holder != chatID {
            slots[k].holder = chatID
            slots[k].dirty = true  // until prepare's wipe proves the slot empty
        }
        slots[k].busy += 1
    }

    /// Wipes what the slot served before this chat (each variant used since the last wipe, and the variant about to be
    /// used if this process has not wiped it yet), and verifies the scratch folder is empty each time.
    private func prepare(_ k: Int, for chatID: String, network: Bool) async throws {
        while let t = slots[k].prep { _ = try? await t.value }  // another call of this chat is wiping the slot
        guard slots[k].holder == chatID else { throw SlotError.wipeFailed(slot: k + 1, "an earlier wipe failed") }
        var toWipe: Set<Bool> = []
        if slots[k].dirty { toWipe = slots[k].used.union([network]) }
        else if !slots[k].used.contains(network) { toWipe = [network] }
        if !toWipe.isEmpty {
            let slot = k + 1
            let t = Task {
                for v in toWipe.sorted(by: { !$0 && $1 }) {
                    var ok = false
                    var why = "scratch not empty after the wipe"
                    for _ in 0..<2 where !ok {  // one retry: a service that just exited is relaunched by the second call
                        do { ok = try await self.wipe(slot, v) } catch { why = "\(error)" }
                    }
                    guard ok else { throw SlotError.wipeFailed(slot: slot, why) }
                }
            }
            slots[k].prep = t
            do {
                try await t.value
                slots[k].prep = nil
            } catch {
                slots[k].prep = nil
                slots[k].dirty = true
                slots[k].holder = nil
                throw error
            }
            if slots[k].dirty { slots[k].used = [] }
        }
        slots[k].dirty = false
        slots[k].used.insert(network)
    }

    private func wipe(_ slot: Int, _ network: Bool) async throws -> Bool {
        if let wiper { return try await wiper(slot, network, nil) }
        return try await FileToolsClient(serviceName: FileToolsProtocol.slotServiceName(slot, network: network, prefix: prefix))
            .resetAck(chatID: "slot-wipe", wipeSlot: true).scratchEmpty
    }

    /// Hands idle slots to waiters in arrival order (a waiter whose chat already holds an idle slot gets that one).
    private func serveWaiters() {
        while !waiters.isEmpty {
            let w = waiters[0]
            let k: Int
            if let own = (0..<capacity).first(where: { slots[$0].holder == w.chatID && slots[$0].busy == 0 && !slots[$0].dirty }) {
                k = own
                slots[k].busy += 1
            } else if let free = idleSlot() {
                k = free
                take(k, for: w.chatID)
            } else { return }
            waiters.removeFirst()
            w.continuation.resume(returning: k)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let i = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }

    // MARK: Waiting state (the ActivityLine reads it)

    /// Posted (main queue not guaranteed) whenever a call starts or stops waiting for a slot.
    public static let waitingDidChange = Notification.Name("FileToolsSlots.waitingDidChange")
    private static let waitingKeys = Mutex<Set<String>>([])

    /// True while the tool call (or chat) `key` waits for a free sandbox.
    public static func isWaiting(_ key: String) -> Bool { waitingKeys.withLock { $0.contains(key) } }

    private static func setWaiting(_ key: String, _ on: Bool) {
        let changed = waitingKeys.withLock { on ? $0.insert(key).inserted : $0.remove(key) != nil }
        if changed { NotificationCenter.default.post(name: waitingDidChange, object: nil) }
    }
}
