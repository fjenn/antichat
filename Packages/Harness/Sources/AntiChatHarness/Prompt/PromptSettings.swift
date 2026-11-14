// The prompt inputs a chat window composes from (M1.T14 step 3). Personalization (Settings, M1.T22), the frozen
// memory snapshot (M8) and the tool set (M1.T16) write here; every TurnController reads a snapshot once per turn,
// so an edit takes effect at the next turn and never mid-turn.
import CryptoKit
import Foundation
import Synchronization

public final class PromptSettings: Sendable {
    private let state: Mutex<PromptInputs>
    /// M1.T20: a read-only view of another `PromptSettings` (the incognito chat's Personalized / Unpersonalized
    /// choice); nil = this object holds its own inputs.
    private let derived: (@Sendable () -> PromptInputs)?

    public init(_ inputs: PromptInputs = PromptInputs()) {
        state = Mutex(inputs)
        derived = nil
    }

    /// M1.T20: reads `base` through `transform` at every turn; `update` is a no-op (an incognito chat never
    /// writes Personalization or memory, R-090).
    public init(derivedFrom base: PromptSettings, _ transform: @escaping @Sendable (PromptInputs) -> PromptInputs) {
        state = Mutex(PromptInputs())
        derived = { transform(base.inputs) }
    }

    public var isReadOnly: Bool { derived != nil }

    public var inputs: PromptInputs {
        if let derived { return derived() }
        return state.withLock { $0 }
    }

    public func update(_ body: (inout PromptInputs) -> Void) {
        guard derived == nil else { return }
        state.withLock { body(&$0) }
    }
}

extension UUID {
    /// A stable session id for a chat (the engines key their prefix cache / llama-server slot by it): the first
    /// 16 bytes of SHA-256("antichat.session." + chatID), as an RFC 4122 v8 (name-based, custom hash) UUID.
    public static func session(forChat chatID: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(("antichat.session." + chatID).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
