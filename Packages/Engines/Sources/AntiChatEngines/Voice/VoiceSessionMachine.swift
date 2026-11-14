// M3.T10 step 1 (R-052, R-282; P-media-03: states ported from speech-core via speech-swift `VoicePipeline`:
// idle / listening / transcribing / thinking / speaking, eager STT, interruption + post-playback guard). The voice
// session's transitions as a pure function `next(state, event) -> (state, [effect])`, unit-tested without audio
// (`VoiceSessionStateTests`); `VoiceSession` performs the effects.
//   idle ─start→ listening ─speechStarted→ transcribing ─turnEnded→ thinking ─replyAudio→ speaking ─replyDone→ listening
//   speaking ─bargeCandidate→ (output paused) ─bargeConfirmed→ transcribing (flush, cancel, onset audio kept)
//                                             └ bargeFalseAlarm→ speaking (output resumes)
//   thinking ─bargeConfirmed→ transcribing (cancel the generation; nothing was spoken)
// Mic mute drops input frames (no turn can start); speaker mute silences the output but keeps the clock running (the
// reply is still "spoken" for truncation). Half-duplex (M3.T12) ignores barge-in while speaking.
import AntiChatEngineProtocol
import Foundation

public struct VoiceSessionMachine: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case start
        case speechStarted
        /// Stage 2 ended the user's turn; the final transcript follows (`finalReady`).
        case turnEnded(VoiceTurnEndReason)
        case finalReady(text: String)
        /// The app streams the reply of `turnID` (first text for the turn).
        case replyStarted(turnID: UUID)
        /// The first audio of the reply reached the output.
        case replyAudio
        /// Every chunk of the reply played (and the app said the reply text is complete).
        case replyDone
        case bargeCandidate
        case bargeConfirmed
        /// Push-to-talk pressed while the assistant speaks / thinks: an explicit interrupt, also in half duplex.
        case pttInterrupt
        case bargeFalseAlarm
        /// No user turn follows (push-to-talk barge-in without Space held): back to listening.
        case abandonTurn
        case muteMic(Bool)
        case muteSpeaker(Bool)
        case setHalfDuplex(Bool)
        case end
    }

    public enum Effect: Sendable, Equatable {
        case startCapture
        case stopCapture
        case emitState(VoiceState)
        case emitTurnEnded(VoiceTurnEndReason)
        case emitFinal(String)
        case pauseOutput
        case resumeOutput
        /// Flush the output and report the spoken span of `turnID` (`ttsStopped(.bargeIn)` + `spokenSpan`).
        case stopSpeech(turnID: UUID?, reason: TTSStopReason)
        /// Tell the app to cancel the generation (`ttsStopped(.bargeIn)` carries it when nothing was spoken).
        case cancelGeneration(turnID: UUID?)
        case setOutputMuted(Bool)
    }

    public private(set) var state: VoiceState = .idle
    public private(set) var turnID: UUID?
    public private(set) var micMuted = false
    public private(set) var speakerMuted = false
    public private(set) var halfDuplex = false
    /// Output paused on a barge-in candidate.
    public private(set) var outputPaused = false

    public init() {}

    /// Applies `event`; returns the effects to perform, in order.
    public mutating func next(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .start):
            state = .listening
            return [.startCapture, .emitState(.listening)]
        case (_, .end):
            guard state != .idle else { return [] }
            let speaking = state == .speaking
            let id = turnID
            self = VoiceSessionMachine()
            return (speaking ? [.stopSpeech(turnID: id, reason: .stopped)] : []) + [.stopCapture, .emitState(.idle)]
        case (.idle, _):
            return []

        case (_, .muteMic(let on)):
            micMuted = on
            return []
        case (_, .muteSpeaker(let on)):
            speakerMuted = on
            return [.setOutputMuted(on)]
        case (_, .setHalfDuplex(let on)):
            halfDuplex = on
            return []

        case (.listening, .speechStarted):
            guard !micMuted else { return [] }
            state = .transcribing
            return [.emitState(.transcribing)]
        case (.transcribing, .turnEnded(let reason)):
            return [.emitTurnEnded(reason)]
        case (.transcribing, .finalReady(let text)):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .listening  // nothing recognisable (noise): back to listening, no turn
                return [.emitState(.listening)]
            }
            state = .thinking
            return [.emitFinal(text), .emitState(.thinking)]
        // A typed message during the session (M3.T11) also gets a spoken reply.
        case (.listening, .replyStarted(let id)), (.thinking, .replyStarted(let id)):
            turnID = id
            if state == .listening { state = .thinking; return [.emitState(.thinking)] }
            return []
        case (.thinking, .replyAudio):
            state = .speaking
            return [.emitState(.speaking)]
        case (.speaking, .replyDone), (.thinking, .replyDone):
            state = .listening
            turnID = nil
            outputPaused = false
            return [.emitState(.listening)]

        case (.speaking, .bargeCandidate):
            guard !halfDuplex, !micMuted, !outputPaused else { return [] }
            outputPaused = true
            return [.pauseOutput]
        case (.speaking, .bargeFalseAlarm):
            guard outputPaused else { return [] }
            outputPaused = false
            return [.resumeOutput]
        case (.speaking, .bargeConfirmed), (.speaking, .pttInterrupt):
            guard event == .pttInterrupt || !halfDuplex, !micMuted else { return [] }
            let id = turnID
            state = .transcribing
            turnID = nil
            outputPaused = false
            return [.stopSpeech(turnID: id, reason: .bargeIn), .cancelGeneration(turnID: id), .emitState(.transcribing)]
        case (.transcribing, .abandonTurn):
            state = .listening
            return [.emitState(.listening)]
        case (.thinking, .bargeConfirmed), (.thinking, .pttInterrupt):
            guard !micMuted else { return [] }
            let id = turnID
            state = .transcribing
            turnID = nil
            return [.cancelGeneration(turnID: id), .emitState(.transcribing)]

        default:
            return []
        }
    }
}
