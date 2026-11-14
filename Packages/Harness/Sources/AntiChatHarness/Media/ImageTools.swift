// M4.T06 step 1/3 (R-286, R-236): `create_image` / `edit_image` as registered tools. A valid call becomes one job of
// the app's MediaJobQueue (one heavy GPU job at a time; the helper's scheduler does the chat → diffusion handoff,
// NFR-M3) and the call waits for its terminal state; the result the model sees is `ImageTurnPolicy.Outcome` JSON.
// The detector manifest travels with the job: without it the helper fails closed (D-006).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation

/// The installed photo models, resolved by the composition root (catalog selection + install views).
public protocol PhotoModelProviding: Sendable {
    /// The model set for `tool` on this Mac (nil = Photo not installed / no edit model on this tier).
    func modelSet(for tool: String) async -> ImageModelSet?
    /// The Mac's speed class (resolution base, S1/S2 768², S3/S4 1024²).
    func speedClass() async -> ImageSpeedClass
    /// The installed ChildSafetyCheck files (nil = missing ⇒ every job fails closed).
    func safetyManifest() async -> SafetyManifest?
    /// The file of a picture the user referenced (`source_image_id` / `mask_id`), M4.T13.
    func imagePath(_ id: String) async -> String?
    /// M4.T07 step 6 (NFR-B2): Low Power Mode / Battery saver → image defaults one resolution step lower.
    func mediaStepDown() async -> Bool
    /// M4.T15: the installed `img-erase` (LaMa `LaMa.mlpackage` directory); nil = not installed (Erase falls back to the
    /// edit model's inpaint).
    func eraseModelPath() async -> String?
}

public extension PhotoModelProviding {
    func mediaStepDown() async -> Bool { false }
    func eraseModelPath() async -> String? { nil }
}

public struct ImageTools: Sendable {
    public let queue: MediaJobQueue
    public let photo: any PhotoModelProviding

    public init(queue: MediaJobQueue, photo: any PhotoModelProviding) {
        self.queue = queue
        self.photo = photo
    }

    public func tools() -> [RegisteredTool] {
        [tool(name: CreateImageTool.name, description: CreateImageTool.description, schema: CreateImageTool.parametersJSON),
         tool(name: EditImageTool.name, description: EditImageTool.description, schema: EditImageTool.parametersJSON)]
    }

    func tool(name: String, description: String, schema: String) -> RegisteredTool {
        let queue = queue, photo = photo
        return RegisteredTool(name: name, description: description, parametersJSON: schema, sideEffect: .read,
                              outputIsUntrusted: false) { args in
            try await Self.run(name, args, queue: queue, photo: photo).resultJSON
        }
    }

    /// One call → one job → its outcome.
    static func run(_ tool: String, _ args: String, queue self_queue: MediaJobQueue, photo: any PhotoModelProviding,
                    chatID: String? = TurnContext.chatID, tier: DeviceTier = DeviceTier.current()) async throws -> ImageTurnPolicy.Outcome {
        var call = try ImageRequestBuilder.parse(args, tool: tool)
        // M4.T07 step 2 (R-030 AC2): an aspect chip in the composer wins over the model's pick.
        if TurnContext.imageEditBest { call.quality = "best" }
        if let forced = TurnContext.imageAspect, CreateImageTool.aspects.contains(forced) { call.aspect = forced; call.aspectGiven = true }
        // M4.T13: edits default to the quick model (the create model, klein img2img); the user's Best quality asks for img-edit
        // and falls back to quick where it is not installed.
        var picked: ImageModelSet?
        if tool == EditImageTool.name, call.quality == "best" { picked = await photo.modelSet(for: EditImageTool.bestModelKey) }
        if picked == nil { picked = await photo.modelSet(for: tool) }
        guard let model = picked, let chatID else { return .unavailable }
        // R-285 AC6 (D-006, Q-015 r5): missing detectors show the repair card and submit no job (before: the job ran
        // to the helper's gate and failed there, so a job card and a queued job appeared first).
        if let repair = SafetyStatus.preflight(await photo.safetyManifest()).repairBytes {
            let outcome = ImageTurnPolicy.Outcome.safetyMissing(sizeBytes: repair)
            MediaJobQueue.endedWithoutJob(call: TurnContext.toolCallID, resultJSON: outcome.resultJSON)
            return outcome
        }
        // M5.T14 review P1-1 (M4 review P1-3): an incognito session's chat runs on that session's own queue (never the
        // persistent one); a session without one fails closed.
        let db = ToolCallStore.database
        guard let queue = MediaJobQueue.serving(db, app: self_queue) else { return .unavailable }
        // M4.T13: the referenced pictures in this chat's store (artifact / version / attachment id → file + lineage);
        // the provider answers for ids the store does not know.
        let sourceRef = call.sourceImageID.flatMap { ImageEditFlow.resolve($0, database: db, chatID: chatID) }
        var source = sourceRef?.path
        if source == nil, let id = call.sourceImageID { source = await photo.imagePath(id) }
        var mask = call.maskID.flatMap { ImageEditFlow.resolve($0, database: db, chatID: chatID)?.path }
        if mask == nil, let id = call.maskID { mask = await photo.imagePath(id) }
        if tool == EditImageTool.name, source == nil { return .failed(code: "unknownSourceImage") }
        let speed = await photo.speedClass(), stepDown = await photo.mediaStepDown()
        var req = ImageRequestBuilder.request(call, model: model, speed: speed,
                                              livePreviews: ImageTurnPolicy.livePreviews(tier: tier),
                                              stepDown: stepDown, initImagePath: source, maskImagePath: mask)
        if tool == EditImageTool.name, let source {
            ImageEditFlow.apply(mode: call.mode, source: source, mask: mask, to: &req)
            if call.mode == "edit", ImageEditFlow.usesImg2Img(modelKey: req.model.key) {
                req.prompt = ImageEditFlow.img2imgPrompt(instruction: req.prompt, sourceVersionID: sourceRef?.versionID, database: db)
            }
            // Same resolution as the source's aspect (the model's `aspect` only when it asked for another one).
            if !call.aspectGiven, let size = ImageEditFlow.pixelSize(source) {
                (req.width, req.height) = ImageEditFlow.resolution(source: size, speed: speed, stepDown: stepDown)
            }
        }
        // M9 review H3: the turn was stopped before the job was written: none is.
        guard !Task.isCancelled else { return .failed(code: "cancelled") }
        // R-291 AC2: the reply id rides on the row (`message_id`), so a relaunched card can restart an interrupted job.
        let id = try await queue.enqueue(chatID: chatID, messageID: MediaCallKey.messageID(of: TurnContext.toolCallID),
                                         kind: tool == EditImageTool.name ? .edit : .image, image: req,
                                         callID: TurnContext.toolCallID)
        let end = await queue.finished(id)
        switch end.state {
        case .done:
            // M4 review P1-2: the turn was stopped (or its incognito session closed) while the job ran: nothing is
            // stored, the job's files go.
            guard !Task.isCancelled else { await queue.discardFiles(id); return .failed(code: "cancelled") }
            // M4.T07 step 3 (R-030 AC3): the picture becomes an artifact of the chat; its spec keeps the prompt the
            // model wrote (the user's own words stay the user bubble) for ⋯ → Show prompt.
            let target = ImageEditFlow.saveTarget(tool == EditImageTool.name ? sourceRef : nil)
            let saved = end.resultPath.flatMap {
                Self.saveArtifact(path: $0, req: req, call: call, chatID: chatID, revises: target.revises, parentVersion: target.parent)
            }
            // M4 review: a result that could not be stored is a failure (never the job id as an image id); the job's
            // xfer files go once the artifact holds the picture (P1-2) and observers get the stored copy (M5.T14 P1-2).
            guard let saved else { await queue.discardFiles(id); return .failed(code: "save") }
            await queue.resultStored(id, at: saved.path)
            return .done(imageID: saved.artifactID, width: req.width, height: req.height, path: saved.path)
        case .blocked: return .notShown
        case .failed where end.errorCode == MediaJobQueue.safetyMissingCode:
            return .safetyMissing(sizeBytes: await photo.safetyManifest()?.sizeBytes ?? 0)
        case .cancelled: return .failed(code: "cancelled")
        case .lost: return .failed(code: "interrupted")
        default: return .failed(code: end.errorCode ?? "failed")
        }
    }
}

extension ImageTools {
    /// The spec stored with a generated picture (`artifact_version.spec_json`).
    static func specJSON(_ req: ImageRequest, call: ImageRequestBuilder.Call) -> String {
        var o: [String: Any] = ["prompt": call.prompt, "aspect": call.aspect, "seed": req.seed, "width": req.width,
                                "height": req.height, "model": req.model.key, "steps": req.steps, "operation": call.mode]
        if let style = call.style { o["style"] = style }
        if req.lowPower == true { o["low_power"] = true }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Saves the gated result as an `image` artifact of the chat (nil when no chat store or the file is gone).
    /// M4.T09 (R-287): the stored PNG carries the AI mark and the generation details (MediaProvenanceWriter adds
    /// metadata chunks only; the checked pixels are unchanged), and the version row records its operation.
    /// M4.T13: `revises` / `parentVersion` = the edited picture's artifact and version (the result is its next version,
    /// parent = the source version; R-033 AC2); the PNG's `parent` names the same version.
    static func saveArtifact(path: String, req: ImageRequest, call: ImageRequestBuilder.Call, chatID: String,
                             revises: String? = nil, parentVersion: String? = nil) -> SavedArtifact? {
        // M4 review P1-2: a closed incognito store gets no new media root (nil: nothing is written).
        guard let db = ToolCallStore.database, let store = FileOutTools.Stores.shared.openStore(for: db),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let operation = operation(call)
        let info = GenerationInfo(prompt: req.prompt, model: req.model.key, seed: req.seed, steps: req.steps, parent: parentVersion,
                                  operation: operation, width: req.width, height: req.height)
        let marked = (try? MediaProvenanceWriter.writePNG(data, info: info, stripPrompt: false)) ?? data
        return try? store.save(chatID: chatID, kind: "image", filename: "image.png", data: marked, specJSON: specJSON(req, call: call),
                               messageID: nil, revises: revises, operation: operation, parentVersion: parentVersion)
    }

    /// The lineage operation of a call (`mode` of create_image / edit_image; R-287 AC4).
    static func operation(_ call: ImageRequestBuilder.Call) -> ArtifactOperation {
        switch call.mode {
        case "edit": .edit
        case "inpaint": .inpaint
        case "outpaint": .outpaint
        case "variations": .variation
        case "upscale": .upscale
        default: .generate
        }
    }

    /// The prompt the model wrote for a picture (⋯ → Show prompt): its artifact spec, else the call's arguments.
    public static func promptUsed(argumentsJSON: String) -> String? {
        (try? ImageRequestBuilder.parse(argumentsJSON, tool: CreateImageTool.name))?.prompt
    }
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async -> T) async -> T? {
        guard let w = self else { return nil }
        return await f(w)
    }
}
