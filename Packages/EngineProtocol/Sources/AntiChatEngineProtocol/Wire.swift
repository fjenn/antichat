// XPC wire messages (architecture.md §4.3). One `ClientMessage` enum keeps the helper's handler a single
// decode. Replies are asynchronous `ServerMessage`s (not XPC replies) so a request can stream; each carries its
// requestID in a separately decodable header, so an undecodable body still ends the right stream with an
// error instead of hanging it (CR-S-25).
import AntiChatFoundation
import Foundation

public enum ClientMessage: Codable, Sendable {
    case hello(Hello)
    case chat(ChatRequest)
    case cancel(Cancel)
    case warmup(Warmup)
    case evict(Evict)
    case setPolicy(SetPolicy)
    /// M0 spike lanes (M0.T05 voice, M0.T06 image, M0.T07 video).
    case voice(VoiceRequest)
    case image(ImageRequest)
    case video(VideoRequest)
    /// M4.T04: one job of the app's durable media queue (events: `MediaEvent.job`; cancel: `Cancel{image.requestID}`).
    case mediaJob(MediaJobSubmit)
    /// M4 (lead decision): compile the installed ChildSafetyCheck detectors into the helper's cache right after the
    /// Photo/Video pack verifies, so the first image never pays it. Answered with `.search(SearchReply(error:))`.
    case prepareSafety(SafetyPrepareRequest)
    /// M2.T16: search models (answered with `.search`).
    case embed(EmbedRequest)
    case rerank(RerankRequest)
    /// M6.T02: tokens by the model's tokenizer (reply: `.search(SearchReply(tokens:))`).
    case countTokens(CountTokensRequest)
    /// Test/diagnostics probe of the helper's state (R241PathTests, restart tests); answered with `.probe`.
    case probe(requestID: UUID)
    /// M3.T01: dictation, file transcription, voice sessions and read aloud (`VoiceMessages.swift`); events come
    /// back as `StreamItem.voice`, each stream ending with one terminal `EngineEvent`.
    case voiceService(VoiceMessage)
    /// M5.T11: acts on a running media job's stream (`requestID` of its submit): [Resume] on a paused video job.
    /// Fire and forget; the effect arrives on the job's own stream.
    case mediaJobControl(MediaJobControl)
}

/// M5.T11 (NFR-B3/B5): a control message for the running media job of stream `requestID`.
public struct MediaJobControl: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable { case resume }
    public var requestID: UUID
    public var action: Action
    public init(requestID: UUID, action: Action) {
        self.requestID = requestID
        self.action = action
    }
}

/// The helper's answer to `ClientMessage.probe` (integration tests and diagnostics; no content).
public struct HelperProbe: Codable, Sendable, Hashable {
    public var pid: Int32
    public var residentModels: [String]
    /// `MediaOutputGate.trace.count` in the helper: R-241 path rule, chat flows must leave it unchanged.
    public var mediaGateInvocations: Int
    public var sessions: Int
    /// M6.T03 (NFR-M4 check): pinned document prefixes held in memory (nil from an older helper).
    public var pinnedPrefixes: Int?
    /// M8.T09 System report: resident bytes per model key (measured, else catalog footprint; nil from an older helper).
    public var residentBytes: [String: UInt64]?
    /// M8.T09 System report: the scheduler's last model-load wall times in ms, oldest first (nil from an older helper).
    public var loadTimesMs: [Double]?
    /// The helper's phys_footprint now (tests size their budget from it; nil from an older helper).
    public var footprintBytes: UInt64?
    /// M9.T06 (AT-NFR-S3): the helper's `MTLDevice.currentAllocatedSize` now (the soak's Metal sample; nil from an older
    /// helper).
    public var mtlAllocatedBytes: UInt64?

    public init(pid: Int32, residentModels: [String], mediaGateInvocations: Int, sessions: Int, pinnedPrefixes: Int? = nil,
                residentBytes: [String: UInt64]? = nil, loadTimesMs: [Double]? = nil, footprintBytes: UInt64? = nil,
                mtlAllocatedBytes: UInt64? = nil) {
        self.footprintBytes = footprintBytes
        self.mtlAllocatedBytes = mtlAllocatedBytes
        self.residentBytes = residentBytes
        self.loadTimesMs = loadTimesMs
        self.pinnedPrefixes = pinnedPrefixes
        self.pid = pid
        self.residentModels = residentModels
        self.mediaGateInvocations = mediaGateInvocations
        self.sessions = sessions
    }
}

/// One item of a request's stream.
public enum StreamItem: Codable, Sendable, Hashable {
    case engine(EngineEvent)
    case lifecycle(LifecycleEvent)
    case media(MediaEvent)
    /// M3.T01: voice events (kept out of `EngineEvent`, R-229's seven).
    case voice(VoiceEvent)

    public var isTerminal: Bool {
        if case .engine(let e) = self { return e.isTerminal }
        return false
    }
}

public struct ServerMessage: Codable, Sendable {
    public enum Body: Codable, Sendable {
        case helloAck(HelloAck)
        /// Hello refused (`engine.versionMismatch`); the helper exits right after.
        case helloRejected(AntiChatError)
        /// One XPC message per DeltaBatcher flush. `tokens` = generated tokens covered by the deltas in
        /// `items` (bench arrival-rate measurement; not part of the event contract).
        case items([StreamItem], tokens: Int)
        case probe(HelperProbe)
        /// M2.T16: the answer to `.embed` / `.rerank`.
        case search(SearchReply)
    }

    /// nil for handshake replies.
    public var requestID: UUID?
    public var body: Body

    public init(requestID: UUID?, body: Body) {
        self.requestID = requestID
        self.body = body
    }

    public static func items(_ id: UUID, _ items: [StreamItem], tokens: Int = 0) -> ServerMessage {
        ServerMessage(requestID: id, body: .items(items, tokens: tokens))
    }

    public static func engine(_ id: UUID, _ events: EngineEvent...) -> ServerMessage {
        items(id, events.map(StreamItem.engine))
    }
}

/// Decodes only `ServerMessage.requestID` (the fallback when the body does not decode).
public struct ServerMessageHeader: Decodable, Sendable {
    public var requestID: UUID?
}
