// M5.T10 step 4 (R-040 AC1/AC2, R-043; P-media-11 tool path): `create_video` as a registered tool, mirroring
// `create_image` (ImageTools): route → the chat model rewrites the prompt into the call → the plan card (M5.T09,
// hosted by the UI under the call's line through `VideoPlanBroker`) → on [Start] or the countdown, one job of the app's
// MediaJobQueue (the same durable queue, the same helper MediaJobRunner and gate as images, D-006) → the call waits for
// its terminal state → the gated MP4 becomes a `video` artifact of the chat (incognito: the session's temp dir) →
// `jobCompleted` (MediaJobCompleted, R-040 AC2; the system notification is M8) → the outcome JSON the model sees.
//   T2V runs FastMetal (`vid-5b`; `vid-ltx` with its sound track when Sound is on, Normal chats only, K-014); I2V runs
//   sd-server (`vid-i2v`). The I2V source picture is passed as is: it is never checked (D-005, R-043 AC2); the clip is.
//   [Cancel] / [Later] on the card write no job (`not_started`).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation

/// The installed video models and runtime, resolved by the composition root (catalog selection + install views).
public protocol VideoModelProviding: Sendable {
    /// True when video can run here now (pack installed, Mac eligible). false ⇒ `create_video` answers `unavailable`.
    func isAvailable() async -> Bool
    /// The helper request for a plan job: model / runtime paths for `job.spec.model`, the source picture (I2V), the
    /// seed, Sound (LTX), the footprint and the tier budget. nil = a needed file is not installed.
    func request(for job: VideoPlanJob, sourceImagePath: String?, seed: Int64, isEvil: Bool) async -> VideoRequest?
    /// A video job ended with a result (R-040 AC2): the composition root posts `MediaJobCompleted` (Platform).
    func jobCompleted(chatID: String, jobID: String) async
    /// This Mac's speed class ("S1"…"S4"), recorded with each finished run (VideoHistory).
    func speedClass() async -> String
}

public extension VideoModelProviding {
    func jobCompleted(chatID: String, jobID: String) async {}
    func speedClass() async -> String { "" }
}

/// What the plan card under a `create_video` call shows (the UI builds `VideoPlanInput` from it + this Mac's facts).
public struct VideoPlanRequest: Sendable, Equatable {
    public var callID: String
    public var chatID: String
    /// The chat model's rewritten prompt.
    public var prompt: String
    public var intent: VideoPlanPolicy.Intent
    public var sourceImageID: String?
    public var isEvil: Bool
    public var length: VideoLength?
    public var shape: VideoShape?
    public var sound: Bool?
    /// The local runs of every measured preset (VideoHistory; the plan keeps its own preset's).
    public var history: [VideoHistory.Run]

    public init(callID: String, chatID: String, prompt: String, intent: VideoPlanPolicy.Intent, sourceImageID: String? = nil,
                isEvil: Bool = false, length: VideoLength? = nil, shape: VideoShape? = nil, sound: Bool? = nil,
                history: [VideoHistory.Run] = []) {
        self.callID = callID; self.chatID = chatID; self.prompt = prompt; self.intent = intent
        self.sourceImageID = sourceImageID; self.isEvil = isEvil; self.length = length; self.shape = shape; self.sound = sound
        self.history = history
    }
}

/// The plan card's answer: [Start] / the countdown hands the job over; [Cancel] / [Later] write none.
public enum VideoPlanAnswer: Sendable, Equatable {
    case start(VideoPlanJob)
    case cancel
}

/// Pending plan cards by tool call: the `create_video` call waits here; the card (VideoJobActivityCard) answers.
public actor VideoPlanBroker {
    public static let shared = VideoPlanBroker()

    private var pending: [String: VideoPlanRequest] = [:]
    private var waiters: [String: CheckedContinuation<VideoPlanAnswer, Never>] = [:]
    private var answers: [String: VideoPlanAnswer] = [:]
    /// Headless hosts (tests, a turn with no window): answers a request at once (nil = wait for the card).
    private var autoAnswer: (@Sendable (VideoPlanRequest) -> VideoPlanAnswer?)?

    public init() {}

    public func setAutoAnswer(_ f: (@Sendable (VideoPlanRequest) -> VideoPlanAnswer?)?) { autoAnswer = f }

    /// Waits for the card's answer (a cancelled turn answers `.cancel`).
    public func ask(_ r: VideoPlanRequest) async -> VideoPlanAnswer {
        if let a = autoAnswer?(r) {
            answers[r.callID] = a
            return a
        }
        pending[r.callID] = r
        let id = r.callID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                if let a = answers[id] { c.resume(returning: a) } else { waiters[id] = c }
            }
        } onCancel: {
            Task { await self.answer(callID: id, .cancel) }
        }
    }

    /// The card's request for `callID` while it waits for an answer.
    public func request(forCall callID: String) -> VideoPlanRequest? { pending[callID] }

    /// The answer a call got (nil = still pending or unknown).
    public func answer(forCall callID: String) -> VideoPlanAnswer? { answers[callID] }

    public func answer(callID: String, _ a: VideoPlanAnswer) {
        guard answers[callID] == nil else { return }
        answers[callID] = a
        pending[callID] = nil
        waiters.removeValue(forKey: callID)?.resume(returning: a)
    }
}

/// The turn facts `create_video` needs (set by the TurnController around the call; Harness-only task local).
public enum VideoTurnContext {
    public struct Facts: Sendable, Equatable {
        public var route: VideoRoute.Facts
        public var isEvil: Bool
        public init(route: VideoRoute.Facts, isEvil: Bool) {
            self.route = route
            self.isEvil = isEvil
        }
    }

    @TaskLocal public static var current: Facts?
}

/// The tool result of `create_video` (and what the card reads back after a relaunch).
public enum VideoTurnPolicy {
    public static let videoTools: Set<String> = [CreateVideoTool.name]

    public enum Outcome: Sendable, Equatable {
        /// `path` = the stored MP4; `poster` = its first frame (JPEG, written after the gate allowed the clip).
        case done(videoID: String, path: String?, poster: String?)
        /// Withheld by ChildSafetyCheck (the gate): no reason, no detail.
        case notShown
        /// Video or the ChildSafetyCheck detectors are not installed / damaged, or this Mac cannot run it.
        case unavailable
        /// [Cancel] / [Later] on the plan card: no job was written.
        case notStarted
        case failed(code: String)

        public var resultJSON: String {
            switch self {
            case .done(let id, let path, let poster):
                var o: [String: Any] = ["status": "done", "video_id": id]
                if let path { o["path"] = path }
                if let poster { o["poster"] = poster }
                return ImageTurnPolicy.Outcome.json(o)
            case .notShown: return #"{"status":"not_shown"}"#
            case .unavailable: return #"{"status":"unavailable"}"#
            case .notStarted: return #"{"status":"not_started"}"#
            case .failed(let code): return ImageTurnPolicy.Outcome.json(["status": "failed", "error": code])
            }
        }

        public static func parse(_ result: String) -> Outcome? {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any],
                  let status = o["status"] as? String else { return nil }
            switch status {
            case "done": return .done(videoID: o["video_id"] as? String ?? "", path: o["path"] as? String, poster: o["poster"] as? String)
            case "not_shown": return .notShown
            case "unavailable": return .unavailable
            case "not_started": return .notStarted
            case "failed": return .failed(code: o["error"] as? String ?? "")
            default: return nil
            }
        }
    }

    /// T0–T2: the chat model stepped aside for the video model, so the turn ends after the call with no text (the
    /// card is the answer; VideoChatPolicy); T3+: the model speaks after the tool as for images.
    public static func endsTurnSilently(tier: DeviceTier) -> Bool { ImageTurnPolicy.endsTurnWithTemplate(tier: tier) }

    /// M5.T11: the T0–T2 templated text after the call (nil = none: not shown / not started / failed have their card).
    public static func caption(_ outcome: Outcome, caption: String) -> String? {
        if case .done = outcome { return caption }
        return nil
    }

    /// English source of `video.done.caption` (the UI passes the localized string).
    public static let defaultCaption = "Here's your video."

    /// The poster the helper writes beside a clip (`result.mp4` → `result.poster.jpg`, MediaJobRunner.emitVideoResult).
    public static func posterPath(forClip path: String) -> String {
        (path as NSString).deletingPathExtension + ".poster.jpg"
    }
}

public struct VideoTools: Sendable {
    public let queue: MediaJobQueue
    public let video: any VideoModelProviding
    public let broker: VideoPlanBroker

    public init(queue: MediaJobQueue, video: any VideoModelProviding, broker: VideoPlanBroker = .shared) {
        self.queue = queue
        self.video = video
        self.broker = broker
    }

    public func tools() -> [RegisteredTool] {
        let queue = queue, video = video, broker = broker
        return [RegisteredTool(name: CreateVideoTool.name, description: CreateVideoTool.description,
                               parametersJSON: CreateVideoTool.parametersJSON, sideEffect: .read, outputIsUntrusted: false) { args in
            try await Self.run(args, queue: queue, video: video, broker: broker).resultJSON
        }]
    }

    /// One call → the plan card → (on Start) one job → its outcome.
    static func run(_ args: String, queue: MediaJobQueue, video: any VideoModelProviding, broker: VideoPlanBroker,
                    chatID: String? = TurnContext.chatID, callID: String? = TurnContext.toolCallID,
                    facts: VideoTurnContext.Facts? = VideoTurnContext.current,
                    database: AppDatabase? = ToolCallStore.database) async throws -> VideoTurnPolicy.Outcome {
        let call = try CreateVideoTool.parse(args)
        // M5.T14 review P1-1: an incognito chat's job runs on its session's own queue (never the persistent one).
        guard let chatID, let queue = MediaJobQueue.serving(database, app: queue), await video.isAvailable() else { return .unavailable }
        let store = database.map { FileOutTools.Stores.shared.store(for: $0) }
        var routeFacts = facts?.route ?? VideoRoute.Facts()
        if routeFacts.lastImageID == nil, VideoRoute.refersToLastImage(routeFacts.userText) {
            routeFacts.lastImageID = store?.lastImageRef(chatID: chatID)
        }
        let choice = VideoRoute.choose(routeFacts, callSourceImageID: call.sourceImageID)
        // The source picture's file (never checked, D-005): an attachment or artifact of this chat.
        var sourcePath: String?
        if let ref = choice.sourceImageID {
            sourcePath = store?.imagePath(ref: ref, chatID: chatID)
            if sourcePath == nil { return .failed(code: "unknownSourceImage") }
        }
        // M5.T14 review P2: unknown turn facts fail closed — treated as Evil (no Sound / LTX, K-014).
        let isEvil = facts?.isEvil ?? true
        let request = VideoPlanRequest(
            callID: callID ?? UUID().uuidString, chatID: chatID, prompt: call.prompt, intent: choice.intent,
            sourceImageID: choice.sourceImageID, isEvil: isEvil, length: call.length.flatMap(VideoLength.init(rawValue:)),
            shape: call.shape.flatMap(VideoShape.init(rawValue:)), sound: isEvil ? false : call.sound,
            history: database.map { db in
                let store = VideoHistoryStore(db)
                return Set(VideoSpeedTable.bundled.presets.map(\.key)).sorted().flatMap { store.recent(preset: $0) }
            } ?? [])
        guard case .start(let job) = await broker.ask(request) else { return .notStarted }
        let seed = call.seed ?? Int64.random(in: 0..<Int64(Int32.max))
        guard let req = await video.request(for: job, sourceImagePath: sourcePath, seed: seed, isEvil: isEvil) else {
            return .unavailable
        }
        // M9 review H3: the turn was stopped while the card was open or the request was built: no job is written.
        guard !Task.isCancelled else { return .notStarted }
        let started = Date()
        let id = try await queue.enqueue(chatID: chatID, video: req, callID: callID)
        let end = await queue.finished(id)
        let incognito = database?.isInMemory ?? false
        switch end.state {
        case .done:
            // M9 review H3 (as images, M4 review P1-2): the turn was stopped while the job ran — a result that raced the
            // cancel is not stored, and the job's files go.
            guard !Task.isCancelled else { await queue.discardFiles(id); return .failed(code: "cancelled") }
            let path = end.resultPath
            let saved = path.flatMap { Self.saveArtifact(path: $0, req: req, job: job, chatID: chatID, store: store) }
            // M5.T14 review P1-2: the stored copy is the only one (the job's xfer files go once it is saved).
            if let saved { await queue.resultStored(id, at: saved.path) }
            // M5.T08 history (never for incognito: cross-task contract 5).
            if let key = job.historyKey, let est = job.estimatedS, let database {
                let run = VideoHistory.Run(presetKey: key, speedClass: await video.speedClass(), estimatedS: est,
                                           actualS: Date().timeIntervalSince(started))
                _ = try? VideoHistoryStore(database).record(run, incognito: incognito)
            }
            await video.jobCompleted(chatID: chatID, jobID: id)
            let finalPath = saved?.path ?? path
            let poster = finalPath.map(VideoTurnPolicy.posterPath(forClip:)).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
            return .done(videoID: saved?.artifactID ?? id, path: finalPath, poster: poster)
        case .blocked: return .notShown
        case .failed where end.errorCode == MediaJobQueue.safetyMissingCode: return .unavailable
        case .cancelled: return .failed(code: "cancelled")
        case .lost: return .failed(code: "interrupted")
        default: return .failed(code: end.errorCode ?? "failed")
        }
    }

    /// The spec stored with a generated clip (`artifact_version.spec_json`).
    static func specJSON(_ req: VideoRequest, job: VideoPlanJob) -> String {
        var o: [String: Any] = ["prompt": job.prompt, "model": job.spec.model, "mode": job.mode.rawValue, "seed": req.seed,
                                "width": req.width, "height": req.height, "frames": req.frames, "fps": req.fps,
                                "steps": req.steps, "length": job.spec.length.rawValue, "shape": job.spec.shape.rawValue,
                                "sound": job.spec.sound, "operation": job.mode == .i2v ? "animate" : "generate"]
        if let s = job.sourceImageID { o["source_image_id"] = s }
        return ImageTurnPolicy.Outcome.json(o)
    }

    /// Saves the gated clip as a `video` artifact of the chat (+ its poster beside it). Incognito chats' store writes
    /// into the session's temp dir and its in-memory database (no Library row, no history).
    static func saveArtifact(path: String, req: VideoRequest, job: VideoPlanJob, chatID: String, store: ArtifactStore?) -> SavedArtifact? {
        guard let store, let data = FileManager.default.contents(atPath: path),
              let saved = try? store.save(chatID: chatID, kind: "video", filename: "video.mp4", data: data,
                                          specJSON: specJSON(req, job: job), messageID: nil) else { return nil }
        let poster = VideoTurnPolicy.posterPath(forClip: path), dest = VideoTurnPolicy.posterPath(forClip: saved.path)
        if FileManager.default.fileExists(atPath: poster), !FileManager.default.fileExists(atPath: dest) {
            try? FileManager.default.copyItem(atPath: poster, toPath: dest)
        }
        return saved
    }
}
