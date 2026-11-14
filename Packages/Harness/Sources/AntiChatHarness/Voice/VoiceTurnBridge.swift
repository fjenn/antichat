// M3.T10 step 2 (R-052, R-282; G-037): VoiceSession (helper) ↔ the chat's turns (app). The helper hears the user and
// speaks the reply; the chat stays a normal chat:
//   `finalTranscript` → a normal user message + a normal TurnController turn with the chat's mode model (the port's
//   `sendUserText`, the same path as the composer's Send);
//   the reply's text deltas (the port feeds `replyDelta`) → `speak` to the helper, in order; the reply's end →
//   `speakEnd`; a typed message during the session is answered aloud the same way;
//   barge-in (`ttsStopped(.bargeIn)` + `spokenSpan`) → Stop on that turn with the stored text truncated to the spoken
//   span (`stopReply(keepingUTF16:)`, status `interrupted`); later deltas of that turn are dropped.
// M3 review P1-5: a spoken ApprovalCard prompt ends the spoken part of the reply (`speakEnd` after "… Allow?"): the
// helper plays it, goes back to listening (half duplex: the mic opens after the tail) and hears the answer as a normal
// turn, not as a barge-in on a reply that is still "speaking". The text after the approval is a new spoken segment
// (its own helper turn id) of the same reply; its spoken offsets continue after what the first segment stored.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

/// The chat a voice session talks into (ConversationModel in the app; a fake in tests).
@MainActor
public protocol VoiceChatPort: AnyObject {
    /// Sends `text` as a user message (a normal turn). False when it could not be sent.
    func sendUserText(_ text: String) -> Bool
    /// Stops the running reply `assistantID`; `keepingUTF16` = the spoken prefix to store (nil = Stop as usual).
    func stopReply(_ assistantID: String, keepingUTF16: Int?)
    /// NFR-V1: the user paused with `text` heard so far; prefill the chat model with the turn it would send
    /// (speculative: nothing is written; the final transcript is sent as usual).
    func prewarm(_ text: String)
    /// M3.T13 step 4: a spoken answer to the ApprovalCard of `callID` in reply `assistantID`.
    func answerApproval(_ assistantID: String, callID: String, _ answer: ApprovalAnswer)
}

extension VoiceChatPort {
    public func prewarm(_ text: String) {}
    public func answerApproval(_ assistantID: String, callID: String, _ answer: ApprovalAnswer) {}
}

@MainActor
public final class VoiceTurnBridge {
    public weak var port: (any VoiceChatPort)?
    /// Sends one session control to the helper.
    private let send: (VoiceSessionControl.Action) -> Void
    private var turnIDs: [String: UUID] = [:]
    private var assistantOf: [UUID: String] = [:]
    private var finished: Set<String> = []
    private var cancelled: Set<String> = []
    /// The reply currently streaming (the newest one).
    public private(set) var current: String?
    /// Barge-in seen, waiting for its `spokenSpan`.
    private var bargePending = false
    /// M3.T13: the ApprovalCard waiting for an answer (reply, call id); its spoken prompt is not part of the stored
    /// reply, so `spokenSpan` offsets after it are shifted back (`injected`: UTF-16 position in the spoken stream,
    /// length).
    public private(set) var pendingApproval: (assistantID: String, callID: String)?
    private var injected: [UUID: [(at: Int, length: Int)]] = [:]
    private var spokenUTF16: [UUID: Int] = [:]
    /// The stored-reply offset a spoken segment starts at (0 for the reply's first one; P1-5).
    private var segmentBase: [UUID: Int] = [:]
    /// The stored-reply text handed to the helper so far, per reply (the base of its next segment).
    private var storedSoFar: [String: Int] = [:]
    /// `voice.approvalPrompt` ("{action}. Allow?"), resolved by the app; nil = approvals are not spoken.
    public var approvalPrompt: ((String) -> String)?
    /// A reply started (`replyStarted`): the session controller holds its text until it is spoken (F3, round 66).
    var onReplyStarted: ((String) -> Void)?

    public init(send: @escaping (VoiceSessionControl.Action) -> Void) { self.send = send }

    // MARK: Helper → chat

    public func handle(_ event: VoiceEvent) {
        switch event {
        case .finalTranscript(let f):
            let text = f.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // M3.T13 step 4: while an ApprovalCard waits, "allow once" / "always allow" / "deny" answers it.
            if let p = pendingApproval, let answer = VoiceToolPolicy.approvalAnswer(text) {
                pendingApproval = nil
                port?.answerApproval(p.assistantID, callID: p.callID, answer)
                return
            }
            _ = port?.sendUserText(text)
        case .provisionalTranscript(let t):
            let text = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            port?.prewarm(text)
        case .ttsStopped(_, .bargeIn):
            // P1-5: speech over the approval prompt is the answer starting, not an interruption of the reply (which
            // waits for that answer): the prompt stops, the turn runs on, the final transcript answers the card.
            if let p = pendingApproval, p.assistantID == current { return }
            bargePending = true
            // Nothing was speaking yet (barge-in while thinking): the running reply stops with nothing more heard (a
            // reply that already spoke a segment before an approval keeps that segment).
            if let id = current, !finished.contains(id), !cancelled.contains(id), turnIDs[id] == nil {
                cancel(id, keep: storedSoFar[id] ?? 0)
            }
        case .spokenSpan(let turnID, let offset):
            guard bargePending, let id = assistantOf[turnID] else { return }
            bargePending = false
            cancel(id, keep: storedOffset(offset, turnID: turnID))
        default:
            break
        }
    }

    private func cancel(_ id: String, keep: Int) {
        guard !cancelled.contains(id) else { return }
        cancelled.insert(id)
        if !finished.contains(id) { port?.stopReply(id, keepingUTF16: keep) }
    }

    // MARK: Chat → helper

    /// A-M3-T09c: the speculative reply's text so far (the helper may synthesise its first chunk ahead of time).
    public func speculate(_ text: String) {
        guard current == nil, !text.isEmpty else { return }
        send(.speculate(text: text))
    }

    /// A text delta of reply `assistantID` (in order).
    public func replyDelta(_ assistantID: String, _ text: String) {
        guard !cancelled.contains(assistantID), !finished.contains(assistantID), !text.isEmpty else { return }
        let turnID = turnIDs[assistantID] ?? newSegment(assistantID)
        spokenUTF16[turnID, default: 0] += text.utf16.count
        storedSoFar[assistantID, default: 0] += text.utf16.count
        send(.speak(text: text, turnID: turnID))
    }

    /// A new spoken segment of reply `assistantID` (its first, or the one after an approval prompt).
    private func newSegment(_ assistantID: String) -> UUID {
        let id = UUID()
        turnIDs[assistantID] = id
        assistantOf[id] = assistantID
        segmentBase[id] = storedSoFar[assistantID] ?? 0
        current = assistantID
        bargePending = false
        return id
    }

    /// M3.T13 step 4: the ApprovalCard of reply `assistantID` appeared (nil: it went). Its title is spoken in the reply
    /// ("{action}. Allow?"); the next final transcript may answer it.
    public func approvalChanged(_ assistantID: String, _ request: ToolApprovalRequest?) {
        guard let request else {
            if pendingApproval?.assistantID == assistantID { pendingApproval = nil }
            return
        }
        guard !cancelled.contains(assistantID), !finished.contains(assistantID) else { return }
        pendingApproval = (assistantID, request.id)
        guard let prompt = approvalPrompt?(VoiceToolPolicy.spokenAction(tool: request.tool)) else { return }
        let turnID = turnIDs[assistantID] ?? newSegment(assistantID)
        // Its own paragraph, so the chunker speaks it as a sentence of its own.
        let spoken = "\n\n" + prompt + "\n\n"
        let at = spokenUTF16[turnID, default: 0]
        injected[turnID, default: []].append((at, spoken.utf16.count))
        spokenUTF16[turnID] = at + spoken.utf16.count
        send(.speak(text: spoken, turnID: turnID))
        // P1-5: the prompt is the end of this spoken segment: the helper listens for the answer once it played. The
        // reply's next text (after the approval) opens a new segment.
        send(.speakEnd(turnID: turnID))
        turnIDs[assistantID] = nil
    }

    /// A position in the spoken stream → the same position in the stored reply (spoken prompts removed).
    func storedOffset(_ offset: Int, turnID: UUID) -> Int {
        var shift = 0
        for i in injected[turnID] ?? [] where offset > i.at {
            shift += min(i.length, offset - i.at)
        }
        return (segmentBase[turnID] ?? 0) + max(0, offset - shift)
    }

    /// A reply started (before its first delta): barge-in from now on cancels it.
    public func replyStarted(_ assistantID: String) {
        current = assistantID
        bargePending = false
        onReplyStarted?(assistantID)
    }

    /// Reply `assistantID` ended (done, stopped or failed): the last chunk is spoken.
    public func replyFinished(_ assistantID: String) {
        guard !finished.contains(assistantID) else { return }
        finished.insert(assistantID)
        // A reply with no text (an error, a tool-only step) still ends the spoken turn: the helper goes back to listening.
        if !cancelled.contains(assistantID) { send(.speakEnd(turnID: turnIDs[assistantID] ?? UUID())) }
        if current == assistantID { current = nil }
    }
}
