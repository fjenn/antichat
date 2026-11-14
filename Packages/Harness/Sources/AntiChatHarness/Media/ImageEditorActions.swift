// M4.T15 (R-034 AC1/AC2/AC4; G-042): the viewer's direct editor actions — Remove background and Erase. No model turn:
// the user's click is the instruction. Each is one job of the app's MediaJobQueue (`kind: local`, so it waits its turn
// behind any running image job) that the helper runs itself and whose one result passes `MediaOutputGate.checkResult`
// like every Photo output (D-006: the source — generated or uploaded — is never checked; the output always is).
// The allowed result becomes the next version of the picture's artifact (parent = the version shown, operation
// `removeBackground` / `erase`), with the AI mark and generation details (MediaProvenanceWriter).
//   * Erase: the brush's 8-bit mask → a temp PNG → LaMa (`img-erase`, Core ML) + MaskCompositor in the helper. When
//     `img-erase` is not installed, the documented last fallback runs instead: the installed edit model's inpaint
//     through sd-server (`kind: edit`, init + mask), composited the same way (M4.md "Known failure modes").
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization

public struct ImageEditorActions: Sendable {
    public enum Operation: String, Sendable { case removeBackground, erase }

    public enum Outcome: Sendable, Equatable {
        case done(SavedArtifact)
        /// Withheld by the gate (no reason, D-006).
        case notShown
        /// Vision found no subject (`editor.removeBg.none`).
        case noSubject
        /// Photo is not installed (no erase or edit model).
        case unavailable
        /// M4 review P2-5 (R-285 AC6): the ChildSafetyCheck files are missing or damaged; the viewer shows the repair card
        /// with this download size.
        case safetyMissing(sizeBytes: Int64)
        case failed(code: String)
    }

    public let queue: MediaJobQueue
    public let photo: any PhotoModelProviding

    public init(queue: MediaJobQueue, photo: any PhotoModelProviding) {
        self.queue = queue
        self.photo = photo
    }

    private static let sharedBox = Mutex<ImageEditorActions?>(nil)
    /// The app's actions (set with the queue at launch; nil = Photo not wired, e.g. a stub engine without media).
    public static var shared: ImageEditorActions? {
        get { sharedBox.withLock { $0 } }
        set { sharedBox.withLock { $0 = newValue } }
    }

    /// Remove background on `sourceID` (artifact / version id of this chat).
    public func removeBackground(sourceID: String, chatID: String, database: AppDatabase) async -> Outcome {
        await run(.removeBackground, sourceID: sourceID, mask: nil, chatID: chatID, database: database)
    }

    /// Erase the brushed region (`mask`: 8-bit PNG, white = erase) of `sourceID`.
    public func erase(sourceID: String, mask: Data, chatID: String, database: AppDatabase) async -> Outcome {
        await run(.erase, sourceID: sourceID, mask: mask, chatID: chatID, database: database)
    }

    func run(_ op: Operation, sourceID: String, mask: Data?, chatID: String, database: AppDatabase) async -> Outcome {
        guard let source = ImageEditFlow.resolve(sourceID, database: database, chatID: chatID) else {
            return .failed(code: "unknownSourceImage")
        }
        guard let manifest = await photo.safetyManifest() else { return .unavailable }
        // R-285 AC6 (D-006, Q-015 r5): absent detector files show the repair card and submit no job.
        if let repair = SafetyStatus.preflight(manifest).repairBytes { return .safetyMissing(sizeBytes: repair) }
        let size = ImageEditFlow.pixelSize(source.path) ?? (1024, 1024)
        var kind = MediaJobKind.local
        var req: ImageRequest
        switch op {
        case .removeBackground:
            req = Self.localRequest(op, model: ImageModelSet(key: "apple-vision", diffusionModel: "", llm: "", vae: "",
                                                             footprintBytes: 300_000_000), size: size)
        case .erase:
            if let lama = await photo.eraseModelPath() {
                req = Self.localRequest(op, model: ImageModelSet(key: "img-erase", diffusionModel: lama, llm: "", vae: "",
                                                                 footprintBytes: 600_000_000), size: size)
            } else if let edit = await photo.modelSet(for: EditImageTool.name) {
                // Last fallback: sd-server inpaint (composited in the helper like the LaMa path).
                kind = .edit
                req = ImageRequest(model: edit, prompt: Self.erasePrompt, width: size.width, height: size.height,
                                   steps: ImageModelProfile.forKey(edit.key).steps, seed: Int64.random(in: 1...Int64(Int32.max)),
                                   preview: "none", outputPath: "")
                req.model.extraArgs += ImageModelProfile.forKey(edit.key).modelArgs.filter { !req.model.extraArgs.contains($0) }
                let (w, h) = ImageEditFlow.resolution(source: size, speed: await photo.speedClass(), stepDown: false)
                req.width = w
                req.height = h
            } else {
                return .unavailable
            }
        }
        req.initImagePath = source.path
        // M4 review P1-5: the mask lives in the job's own dir (survives a restart of a lost job, goes with the job);
        // P1-3 / M5.T14 review P1-1: an incognito session's chat runs on that session's own queue (none: fail closed).
        guard let queue = MediaJobQueue.serving(database, app: queue) else { return .unavailable }
        let id: String
        do { id = try await queue.enqueue(chatID: chatID, kind: kind, image: req, maskPNG: mask) } catch { return .failed(code: "enqueue") }
        let end = await queue.finished(id)
        switch end.state {
        case .done:
            // M4 review P1-2: a call cancelled meanwhile (the viewer/session went away) stores nothing.
            guard !Task.isCancelled else { await queue.discardFiles(id); return .failed(code: "cancelled") }
            let saved = end.resultPath.flatMap { Self.save(path: $0, op: op, req: req, source: source, chatID: chatID, database: database) }
            await queue.discardFiles(id)
            guard let saved else { return .failed(code: "save") }
            return .done(saved)
        case .blocked: return .notShown
        case .failed where end.errorCode == MediaJobQueue.safetyMissingCode:
            return .safetyMissing(sizeBytes: await photo.safetyManifest()?.sizeBytes ?? 0)
        case .failed where end.errorCode == "noSubject": return .noSubject
        default: return .failed(code: end.errorCode ?? end.state.rawValue)
        }
    }

    static let erasePrompt = "the empty background, seamlessly continuing the surroundings"

    static func localRequest(_ op: Operation, model: ImageModelSet, size: (width: Int, height: Int)) -> ImageRequest {
        var r = ImageRequest(model: model, prompt: "", width: size.width, height: size.height, steps: 1, seed: 0, preview: "none",
                             outputPath: "")
        r.localOperation = op.rawValue
        return r
    }

    /// The allowed result → the next version of the source's artifact (an uploaded source: a new artifact).
    static func save(path: String, op: Operation, req: ImageRequest, source: ArtifactStore.ImageRef, chatID: String,
                     database: AppDatabase) -> SavedArtifact? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let operation: ArtifactOperation = op == .erase ? .erase : .removeBackground
        let target = ImageEditFlow.saveTarget(source)
        let size = ImageEditFlow.pixelSize(path)
        let info = GenerationInfo(prompt: nil, model: req.model.key, seed: req.seed, steps: req.steps, parent: target.parent,
                                  operation: operation, width: size?.width, height: size?.height)
        let marked = (try? MediaProvenanceWriter.writePNG(data, info: info, stripPrompt: false)) ?? data
        let spec = (try? JSONSerialization.data(withJSONObject: ["operation": operation.rawValue, "model": req.model.key],
                                                options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        // M4 review P1-2: a closed incognito store gets no new media root (nil: nothing is written).
        return try? FileOutTools.Stores.shared.openStore(for: database)?.save(
            chatID: chatID, kind: "image", filename: "image.png", data: marked, specJSON: spec, messageID: nil,
            revises: target.revises, operation: operation, parentVersion: target.parent)
    }
}
