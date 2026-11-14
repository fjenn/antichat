// llama-server slot assignment with KV save/restore (M1.T14 step 4 + M1.T20; A-M1-T14a (e) deferred the save/restore
// half here because requests carried no incognito flag). A chat keeps its slot while it has one (`cache_prompt`
// reuses the common prefix); when the least recently used slot is taken over, the evicted chat's KV is saved to
// `--slot-save-path` (`POST /slots/{id}?action=save`) and restored when that chat comes back
// (`?action=restore`), so switching between more chats than slots does not re-prefill whole histories.
// Incognito sessions (`ChatRequest.incognito`, R-090 / IncognitoGuards guard 5) are never saved and never
// restored: their KV lives only in the server's memory and is overwritten by the next chat that takes the slot.
// Pure value logic; `LlamaServerAdapter` performs the returned actions.
import Foundation

struct LlamaSlotTable: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        /// Save `session`'s KV from `slot` before the slot is reused.
        case save(slot: Int, session: UUID)
        /// Load `session`'s saved KV into `slot` before its request.
        case restore(slot: Int, session: UUID)
    }

    let slots: Int
    /// Whether saved KV files may be written at all (`--slot-save-path` configured).
    let persistence: Bool
    private(set) var sessionOfSlot: [Int: UUID] = [:]
    private(set) var lastUse: [Int: UInt64] = [:]
    private(set) var incognito: Set<UUID> = []
    /// Sessions with a saved KV file.
    private(set) var saved: Set<UUID> = []
    private var clock: UInt64 = 0

    init(slots: Int, persistence: Bool) {
        self.slots = slots
        self.persistence = persistence
    }

    /// The slot for `session`'s next request and what must happen first.
    mutating func assign(_ session: UUID, incognito isIncognito: Bool) -> (slot: Int, actions: [Action]) {
        clock += 1
        if isIncognito { incognito.insert(session) }
        if let s = sessionOfSlot.first(where: { $0.value == session })?.key {
            lastUse[s] = clock
            return (s, [])
        }
        let s = (0..<max(slots, 1)).min { (lastUse[$0] ?? 0) < (lastUse[$1] ?? 0) } ?? 0
        var actions: [Action] = []
        if persistence, let evicted = sessionOfSlot[s], !incognito.contains(evicted) {
            actions.append(.save(slot: s, session: evicted))
            saved.insert(evicted)
        }
        if persistence, !isIncognito, saved.contains(session) {
            actions.append(.restore(slot: s, session: session))
        }
        sessionOfSlot[s] = session
        lastUse[s] = clock
        return (s, actions)
    }

    /// A save failed: the session has no usable file.
    mutating func saveFailed(_ session: UUID) { saved.remove(session) }

    /// The file name under `--slot-save-path` (llama-server refuses path separators): model tag + session id.
    static func fileName(session: UUID, modelTag: String) -> String {
        let tag = modelTag.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        return "\(String(String.UnicodeScalarView(tag)).prefix(48))-\(session.uuidString.lowercased()).bin"
    }
}
