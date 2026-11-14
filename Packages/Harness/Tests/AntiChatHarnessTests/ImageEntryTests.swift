// M4.T07 (R-030 AC2/AC3, NFR-B2) below the UI: the aspect chip overrides the model's `aspect`; the picture becomes an
// `image` artifact whose spec keeps the prompt the model wrote (⋯ → Show prompt) while the user's words stay the user
// bubble; Battery saver drops the resolution one step and records it in the job spec. The XCUITest legs
// (ImageEntryTests in App/UITests) are pending Q-015.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct ImageEntryTests {
    static func setup() throws -> (AppDatabase, ChatRecord, FakeMediaTransport, MediaJobQueue) {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let t = FakeMediaTransport()
        let q = MediaJobQueue(database: db, transport: t, xferRoot: FileManager.default.temporaryDirectory, safety: { nil })
        return (db, chat, t, q)
    }

    /// AC2: every aspect chip maps to its ratio (S4: 1024² equal-area, multiples of 64), whatever the model wrote.
    @Test func aspectChipOverridesTheModel() async throws {
        let (_, chat, t, q) = try Self.setup()
        let want: [String: (Int, Int)] = ["1:1": (1024, 1024), "2:3": (832, 1280), "3:2": (1280, 832), "9:16": (768, 1344), "16:9": (1344, 768)]
        for (i, (ratio, wh)) in want.sorted(by: { $0.key < $1.key }).enumerated() {
            let task = Task {
                try await TurnContext.$chatID.withValue(chat.id) {
                    try await TurnContext.$imageAspect.withValue(ratio) {
                        try await ImageTools.run("create_image", #"{"prompt":"a lighthouse","aspect":"1:1"}"#, queue: q, photo: FakePhoto())
                    }
                }
            }
            try await MediaJobQueueTests.until("job \(ratio)") { t.submittedJobs.count == i + 1 }
            let sub = t.submitted[i]
            #expect(sub.image.width == wh.0 && sub.image.height == wh.1, "\(ratio): \(sub.image.width)×\(sub.image.height)")
            let rw = Double(sub.image.width) / Double(sub.image.height), want = Double(wh.0) / Double(wh.1)
            #expect(abs(rw - want) < 0.07)
            t.end(sub.job, .jobCancelled(job: sub.job))
            _ = try await task.value
        }
    }

    @Test func aspectComesFromChipsOnlyWithCreateImage() {
        #expect(TurnController.imageAspect(chips: ["image", "aspect:9:16"]) == "9:16")
        #expect(TurnController.imageAspect(chips: ["aspect:9:16"]) == nil)
        #expect(TurnController.imageAspect(chips: ["image"]) == nil)
    }

    /// AC3: the stored picture's spec carries the prompt the model wrote; the tool returns the artifact id.
    @Test func promptUsedIsStoredWithThePicture() async throws {
        let (db, chat, t, q) = try Self.setup()
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("entry-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }
        let args = #"{"prompt":"A weathered lighthouse on a basalt cliff at dusk, warm window light","aspect":"3:2"}"#
        let task = Task {
            try await TurnContext.$chatID.withValue(chat.id) {
                try await ToolCallStore.$database.withValue(db) {
                    try await ImageTools.run("create_image", args, queue: q, photo: FakePhoto())
                }
            }
        }
        try await MediaJobQueueTests.until("submitted") { t.submittedJobs.count == 1 }
        let sub = t.submitted[0]
        t.end(sub.job, .jobResult(job: sub.job, path: png.path, metadata: [:]))
        guard case .done(let id, _, _, let path) = try await task.value else { Issue.record("not done"); return }
        let spec = try await db.read { db in
            try String.fetchOne(db, sql: "SELECT v.spec_json FROM artifact_version v JOIN artifact a ON a.id = v.artifact_id WHERE a.id = ? AND a.kind = 'image'", arguments: [id])
        }
        let o = try #require(spec.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(o["prompt"] as? String == "A weathered lighthouse on a basalt cliff at dusk, warm window light")
        #expect(o["aspect"] as? String == "3:2")
        #expect(ImageTools.promptUsed(argumentsJSON: args) == o["prompt"] as? String)
        #expect(path.map { FileManager.default.fileExists(atPath: $0) } == true, "the stored picture (the card of a reloaded chat)")
    }

    /// NFR-B2: Battery saver → one resolution step lower (S4 1024² → 768²; S1 768² → 640²), recorded in the spec.
    @Test func lowPowerDropsOneResolutionStep() async throws {
        #expect(ImageRequestBuilder.resolution(aspect: "1:1", speed: .s4, stepDown: true) == (768, 768))
        #expect(ImageRequestBuilder.resolution(aspect: "1:1", speed: .s1, stepDown: true) == (640, 640))
        let (_, chat, t, q) = try Self.setup()
        let task = Task {
            try await TurnContext.$chatID.withValue(chat.id) {
                try await ImageTools.run("create_image", #"{"prompt":"x","aspect":"1:1"}"#, queue: q, photo: FakePhoto(stepDown: true))
            }
        }
        try await MediaJobQueueTests.until("submitted") { t.submittedJobs.count == 1 }
        let sub = t.submitted[0]
        #expect(sub.image.width == 768 && sub.image.height == 768 && sub.image.lowPower == true)
        let row = try #require(try await q.row(sub.job))
        #expect(row.specJSON.contains("\"lowPower\":true"))
        t.end(sub.job, .jobCancelled(job: sub.job))
        _ = try await task.value
    }
}
