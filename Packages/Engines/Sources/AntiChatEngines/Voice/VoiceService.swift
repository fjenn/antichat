// M3.T01 step 5 (architecture §4.3 "Voice"; G-036…G-039): the helper's voice front door. One actor owns the
// voice streams and routes each `VoiceMessage` to its service: dictation and files → `STTServing`, read aloud
// and previews → `TTSServing`, hands-free / push-to-talk sessions → `VoiceSessionServing` (M3.T10; absent until
// then, so sessions answer `voice.unsupported`). Messages that act on a stream (stop, control, end) address it by
// the requestID that opened it; one that names no open stream of the right kind answers `voice.unsupported`.
//
// Models: the app registers the installed, verified voice set (`VoiceModelSet`); each role maps to a scheduler
// residency role and is registered with `PredictiveWarmup` (pack `voice`), so mic hover warms STT (NFR-V10).
// `stt-multi` is on demand only (M3.T05) and never warmed by a hint. The shared AVAudioEngine (VPIO, M3.T09)
// is owned here too; `activeStreams == 0` is the moment it may be torn down.
//
// M3 review P2-1 / P0-1: the router calls `prepare` synchronously for every message in arrival order, before any
// async work: a stream-opening message is registered at once (and its service told, `prepare`), so a stop / control
// / end sent right after it always finds it, even while its models are still leasing.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization

/// Hands-free / push-to-talk conversations (M3.T10 `VoiceSession`).
public protocol VoiceSessionServing: Sendable {
    /// The session `id` was routed (synchronous, before `start`): controls and an End for it are kept from now on.
    func prepare(_ id: UUID)
    func start(_ start: VoiceSessionStart, models: VoiceModelSet, emit: @escaping VoiceEmit) async
    func control(_ control: VoiceSessionControl) async
    func end(_ end: VoiceSessionEnd) async
}

extension VoiceSessionServing {
    public func prepare(_ id: UUID) {}
}

extension VoiceModelRole {
    /// The scheduler's eviction role (E.2.7): the input chain evicts with STT, the voice output with TTS.
    public var residency: ResidencyRole {
        switch self {
        case .stt, .sttEOU, .sttMulti, .vad, .turn: .stt
        case .tts: .tts
        }
    }

    /// Roles a mic / voice-button hover warms (NFR-V10); `stt-multi` loads only when the router needs it.
    public var warmsOnHint: Bool { self != .sttMulti }
}

public actor VoiceService {
    enum StreamKind: Equatable, Sendable { case dictation, file, session, speech }

    final class StreamTable: Sendable {
        let m = Mutex<[UUID: StreamKind]>([:])
        func withLock<R>(_ body: (inout [UUID: StreamKind]) -> R) -> R { m.withLock { body(&$0) } }
    }

    public let stt: any STTServing
    public let tts: any TTSServing
    public let sessions: (any VoiceSessionServing)?
    private let predictive: PredictiveWarmup?
    public private(set) var models = VoiceModelSet(slots: [:])
    /// Closed synchronously from a stream's terminal emit (any thread), so a stop right after it already misses.
    private let open = StreamTable()
    /// Streams registered by `prepare` whose opening message has not reached `handle` yet.
    private let prepared = Mutex<Set<UUID>>([])

    public init(
        stt: any STTServing = STTService(), tts: any TTSServing = TTSService(),
        sessions: (any VoiceSessionServing)? = nil, predictive: PredictiveWarmup? = nil
    ) {
        self.stt = stt
        self.tts = tts
        self.sessions = sessions
        self.predictive = predictive
    }

    /// Open voice streams (dictations, files, sessions, speeches).
    public nonisolated var activeStreams: Int { open.withLock { $0.count } }

    /// Registers a stream-opening message the moment it arrives (synchronous, in arrival order; P2-1). A duplicate id
    /// is left for `handle` to refuse.
    public nonisolated func prepare(_ message: VoiceMessage) {
        let kind: StreamKind
        switch message {
        case .dictationStart: kind = .dictation
        case .transcribeFile: kind = .file
        case .sessionStart:
            guard sessions != nil else { return }  // answered `unsupported` by `handle`
            kind = .session
        case .speak: kind = .speech
        default: return
        }
        let id = message.requestID
        let fresh = open.withLock { o -> Bool in
            guard o[id] == nil else { return false }
            o[id] = kind
            return true
        }
        guard fresh else { return }
        prepared.withLock { _ = $0.insert(id) }
        switch kind {
        case .session: sessions?.prepare(id)
        case .speech: tts.prepare(id)
        case .dictation: stt.prepareDictation(id)
        case .file: break
        }
    }

    /// Routes one message. `emit` sends on `message.requestID`'s stream.
    public func handle(_ message: VoiceMessage, emit: @escaping VoiceEmit) async {
        switch message {
        case .models(let set):
            await register(set)
            emit([.engine(.done(.stop))])
        case .dictationStart(let m):
            guard opens(m.requestID, .dictation, emit) else { return }
            await stt.startDictation(m, models: models, emit: tracking(m.requestID, emit))
        case .dictationStop(let m):
            guard addresses(m.requestID, .dictation, emit) else { return }
            await stt.stopDictation(m)
        case .transcribeFile(let m):
            guard opens(m.requestID, .file, emit) else { return }
            await stt.transcribe(m, models: models, emit: tracking(m.requestID, emit))
        case .sessionStart(let m):
            guard let sessions else { return unsupported("voice session (M3.T10)", emit) }
            guard opens(m.requestID, .session, emit) else { return }
            await sessions.start(m, models: models, emit: tracking(m.requestID, emit))
        case .sessionControl(let m):
            guard let sessions else { return unsupported("voice session (M3.T10)", emit) }
            guard addresses(m.requestID, .session, emit) else { return }
            await sessions.control(m)
        case .sessionEnd(let m):
            guard let sessions else { return unsupported("voice session (M3.T10)", emit) }
            guard addresses(m.requestID, .session, emit) else { return }
            await sessions.end(m)
        case .speak(let m):
            guard opens(m.requestID, .speech, emit) else { return }
            await tts.speak(m, models: models, emit: tracking(m.requestID, emit))
        case .speakStop(let m):
            guard addresses(m.requestID, .speech, emit) else { return }
            await tts.stop(m)
        }
    }

    /// The registered slot of `role`, if installed.
    public func slot(_ role: VoiceModelRole) -> ModelSlot? { models.slots[role] }

    private func register(_ set: VoiceModelSet) async {
        models = set
        guard let predictive else { return }
        for role in VoiceModelRole.allCases where role.warmsOnHint {
            if let slot = set.slots[role] { await predictive.register(pack: "voice", role: role.residency, slot: slot) }
        }
    }

    private func opens(_ id: UUID, _ kind: StreamKind, _ emit: VoiceEmit) -> Bool {
        if prepared.withLock({ $0.remove(id) }) != nil, open.withLock({ $0[id] }) == kind { return true }
        let fresh = open.withLock { o -> Bool in
            guard o[id] == nil else { return false }
            o[id] = kind
            return true
        }
        if !fresh { emit([.engine(.error(.engine("duplicateRequestID", id.uuidString)))]) }
        return fresh
    }

    private func addresses(_ id: UUID, _ kind: StreamKind, _ emit: VoiceEmit) -> Bool {
        guard open.withLock({ $0[id] }) == kind else {
            unsupported("no open \(kind) stream \(id.uuidString)", emit)
            return false
        }
        return true
    }

    private func unsupported(_ detail: String, _ emit: VoiceEmit) {
        emit([.engine(.error(.voice("unsupported", detail)))])
    }

    /// Wraps a stream's emitter so its terminal event closes the stream here.
    private func tracking(_ id: UUID, _ emit: @escaping VoiceEmit) -> VoiceEmit {
        let open = self.open
        return { items in
            if items.contains(where: \.isTerminal) { _ = open.withLock { $0.removeValue(forKey: id) } }
            emit(items)
        }
    }
}
