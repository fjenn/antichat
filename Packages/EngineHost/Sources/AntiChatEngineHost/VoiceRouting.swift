// M3.T01 step 5: `ClientMessage.voiceService` in the helper. A stream-opening message (dictation start, file
// transcription, session start, speak, model registration) runs as its own request (registered in the router,
// cancellable, exactly one terminal); a message that acts on an open stream (stop, control, end) runs beside it
// and reports on that stream. FluidAudio is offline from helper start (`VoiceEnvironment.lockDown`, D-11).
// M3 review P2-1: XPC delivers one session's messages in order, and they stay in order here: an opening message is
// registered synchronously (`VoiceService.prepare`) before its request Task starts, and the messages acting on one
// stream run one after another (`VoiceOrder`, a FIFO per request id), never as racing unstructured Tasks.
import AntiChatEngineProtocol
import AntiChatEngines
import AntiChatFoundation
import Foundation
import Synchronization

extension EngineCore {
    func runVoiceService(_ message: VoiceMessage, emit: @escaping Emit) async {
        if case .models = message { await runtime.attach(scheduler) }
        await voiceService.handle(message) { items in emit(items, 0) }
    }
}

extension SessionRouter {
    func routeVoice(_ message: VoiceMessage) {
        let core = core, id = message.requestID, emit = emitter(id)
        core.voiceService.prepare(message)
        if message.opensStream {
            start(id) { await core.runVoiceService(message, emit: emit) }
        } else {
            voiceOrder.enqueue(id) { await core.runVoiceService(message, emit: emit) }
        }
    }
}

/// One FIFO per request id for the voice messages that act on an open stream (stop, control, end): each runs after
/// the previous one for the same id finished (speak deltas stay in order, `speakEnd` follows the last delta, `pttUp`
/// follows `pttDown`). Different streams do not wait for each other.
final class VoiceOrder: Sendable {
    private struct Tail {
        var seq: UInt64
        var task: Task<Void, Never>
    }
    private let tails = Mutex<[UUID: Tail]>([:])
    private let counter = Mutex<UInt64>(0)

    func enqueue(_ id: UUID, _ body: @escaping @Sendable () async -> Void) {
        let seq = counter.withLock { c -> UInt64 in
            c &+= 1
            return c
        }
        tails.withLock { t in
            let previous = t[id]?.task
            let task = Task { [weak self] in
                await previous?.value
                await body()
                self?.tails.withLock { t in if t[id]?.seq == seq { t[id] = nil } }
            }
            t[id] = Tail(seq: seq, task: task)
        }
    }

    /// Ids with queued messages (tests).
    var queued: Int { tails.withLock { $0.count } }
}
