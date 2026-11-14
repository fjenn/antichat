// AT-034 AC1 app-side leg (R-034; M4.T15): Remove background and Erase are direct editor actions — one `local` job each
// on the app's MediaJobQueue (no model turn), with the source file (+ the brush mask for Erase) in the spec; the allowed
// result becomes the picture's next version (parent = the version shown, operation removeBackground / erase) with
// matching PNG provenance; a withheld result is `notShown`; no subject maps to `noSubject`; without img-erase, Erase
// falls back to the edit model's inpaint through sd-server (`kind: edit`, init + mask).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct ImageEditorActionsTests {
    struct Photo: PhotoModelProviding {
        var erase: String? = "/m/LaMa.mlpackage"
        var edit = true
        func modelSet(for tool: String) async -> ImageModelSet? { edit ? FakePhoto.set : nil }
        func speedClass() async -> ImageSpeedClass { .s1 }
        var detectors = true
        func safetyManifest() async -> SafetyManifest? { detectors ? FakeSafety.installed : FakeSafety.absent }
        func imagePath(_ id: String) async -> String? { nil }
        func eraseModelPath() async -> String? { erase }
    }

    /// A chat with one generated picture (v1); returns its artifact id.
    static func picture(_ f: ImageEditFlowTests.Fixture) async throws -> String {
        let (o, _) = try await f.call("create_image", #"{"prompt":"a vase on a table"}"#)
        return ImageEditFlowTests.id(o)
    }

    static func runAction(_ f: ImageEditFlowTests.Fixture, photo: Photo, _ body: @escaping @Sendable (ImageEditorActions) async -> ImageEditorActions.Outcome,
                          answer: @escaping (MediaJobSubmit) -> MediaJobEvent?) async throws -> (ImageEditorActions.Outcome, MediaJobSubmit) {
        let actions = ImageEditorActions(queue: f.queue, photo: photo)
        let before = f.transport.submittedJobs.count
        let task = Task { await body(actions) }
        for _ in 0..<500 where f.transport.submittedJobs.count == before { try await Task.sleep(for: .milliseconds(5)) }
        let sub = try #require(f.transport.submitted.dropFirst(before).first)
        if let e = answer(sub) { f.transport.end(sub.job, e) }
        return (await task.value, sub)
    }

    @Test func removeBackgroundMakesTheNextVersion() async throws {
        let f = try ImageEditFlowTests.Fixture()
        let art = try await Self.picture(f)
        let v1 = try f.versions(art)[0]
        let out = f.dir.appendingPathComponent("cut.png")
        try ImageEditFlowTests.png(96, 64, gray: 0.8).write(to: out)
        let db = f.db, chat = f.chat.id
        let (o, sub) = try await Self.runAction(f, photo: Photo(), { await $0.removeBackground(sourceID: art, chatID: chat, database: db) }) {
            .jobResult(job: $0.job, path: out.path, metadata: [:])
        }
        #expect(sub.kind == .local && sub.image.localOperation == "removeBackground")
        #expect(sub.image.initImagePath == (try f.path(v1)) && sub.image.maskImagePath == nil)
        guard case .done(let saved) = o else { Issue.record("\(o)"); return }
        #expect(saved.artifactID == art && saved.version == 2)
        let v2 = try f.versions(art)[1]
        #expect(v2.parentVersionID == v1.id && v2.operation == "removeBackground")
        let info = try #require(MediaProvenanceWriter.info(fromPNG: try Data(contentsOf: URL(fileURLWithPath: saved.path))))
        #expect(info.parent == v1.id && info.operation == .removeBackground)
    }

    @Test func eraseSendsTheMaskAndMapsOutcomes() async throws {
        let f = try ImageEditFlowTests.Fixture()
        let art = try await Self.picture(f)
        let mask = ImageEditFlowTests.png(96, 64, gray: 1)
        let db = f.db, chat = f.chat.id
        // Withheld → notShown; the mask file is gone after the job.
        let (blocked, sub) = try await Self.runAction(f, photo: Photo(), { await $0.erase(sourceID: art, mask: mask, chatID: chat, database: db) }) {
            .jobBlocked(job: $0.job)
        }
        #expect(sub.kind == .local && sub.image.localOperation == "erase" && sub.image.model.diffusionModel == "/m/LaMa.mlpackage")
        #expect(blocked == .notShown)
        #expect(!FileManager.default.fileExists(atPath: try #require(sub.image.maskImagePath)))
        #expect(try f.versions(art).count == 1, "nothing stored")
        // No subject.
        let (none, _) = try await Self.runAction(f, photo: Photo(), { await $0.removeBackground(sourceID: art, chatID: chat, database: db) }) {
            .jobFailed(job: $0.job, code: "noSubject")
        }
        #expect(none == .noSubject)
        // No img-erase installed → sd-server inpaint fallback (kind edit, init + mask, the edit model).
        let out = f.dir.appendingPathComponent("erased.png")
        try ImageEditFlowTests.png(96, 64, gray: 0.6).write(to: out)
        let (done, fb) = try await Self.runAction(f, photo: Photo(erase: nil), { await $0.erase(sourceID: art, mask: mask, chatID: chat, database: db) }) {
            .jobResult(job: $0.job, path: out.path, metadata: [:])
        }
        #expect(fb.kind == .edit && fb.image.localOperation == nil && fb.image.initImagePath != nil && fb.image.maskImagePath != nil)
        guard case .done = done else { Issue.record("\(done)"); return }
        #expect(try f.versions(art).last?.operation == "erase")
    }
}
