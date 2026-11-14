// M9.T02 step 5 (AT-NFR-A5 unit leg, A-M9-T02a): a picture gets one model description (stored by content hash, in the
// UI language), an edit wins over the model, incognito pictures are never stored, and orphans are swept.
import AntiChatStorage
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

@Suite struct ImageDescriptionServiceTests {
    static func picture(_ name: String, bytes: UInt8 = 7, dir: URL = FileManager.default.temporaryDirectory) throws -> String {
        let url = dir.appendingPathComponent("\(name)-\(UUID().uuidString).png")
        try Data(repeating: bytes, count: 64).write(to: url)
        return url.path
    }

    @Test func describesOnceAndStoresByHash() async throws {
        let db = try AppDatabase.inMemory()
        let calls = Mutex(0)
        let prompts = Mutex<[String]>([])
        let service = ImageDescriptionService(store: ImageDescriptionStore(database: db), language: { "de" }) { _, _, prompt in
            calls.withLock { $0 += 1 }
            prompts.withLock { $0.append(prompt) }
            return "  Description: \"Ein Leuchtturm in der Dämmerung.\"\n"
        }
        let path = try Self.picture("a")
        let d = await service.ensure(path)
        #expect(d?.text == "Ein Leuchtturm in der Dämmerung.")
        #expect(d?.source == .auto && d?.language == "de")
        _ = await service.ensure(path)
        #expect(calls.withLock { $0 } == 1, "the model runs once per picture")
        #expect(prompts.withLock { $0.first }?.contains("Answer in German") == true)
        // Same bytes elsewhere (a saved copy) share the description.
        let copy = try Self.picture("b")
        #expect(await service.current(copy)?.text == "Ein Leuchtturm in der Dämmerung.")
        let sha = try #require(ImageDescriptionService.sha256(of: path))
        #expect(try ImageDescriptionStore(database: db).get(sha256: sha)?.text == "Ein Leuchtturm in der Dämmerung.")
    }

    @Test func editWinsOverTheModel() async throws {
        let db = try AppDatabase.inMemory()
        let store = ImageDescriptionStore(database: db)
        let service = ImageDescriptionService(store: store, language: { "en" }) { _, _, _ in "A lighthouse." }
        let path = try Self.picture("c", bytes: 9)
        await service.setUser(path, text: "  My lighthouse at dusk  ")
        #expect(await service.ensure(path)?.text == "My lighthouse at dusk")
        let sha = try #require(ImageDescriptionService.sha256(of: path))
        #expect(try store.set(sha256: sha, ImageDescription(text: "model", source: .auto, language: "en")) == false)
        #expect(try store.get(sha256: sha)?.source == .user)
    }

    @Test func incognitoPicturesStayInMemory() async throws {
        let db = try AppDatabase.inMemory()
        let store = ImageDescriptionStore(database: db)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(IncognitoSession.tempPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = ImageDescriptionService(store: store, language: { "en" }) { _, _, _ in "A cat." }
        let path = try Self.picture("d", bytes: 11, dir: dir)
        #expect(await service.ensure(path)?.text == "A cat.")
        let sha = try #require(ImageDescriptionService.sha256(of: path))
        #expect(try store.get(sha256: sha) == nil)
    }

    @Test func noModelMeansNoDescription() async throws {
        let service = ImageDescriptionService(store: ImageDescriptionStore(database: try AppDatabase.inMemory())) { _, _, _ in nil }
        #expect(await service.ensure(try Self.picture("e", bytes: 13)) == nil)
    }

    @Test func sweepRemovesOrphans() throws {
        let db = try AppDatabase.inMemory()
        let store = ImageDescriptionStore(database: db)
        try store.set(sha256: String(repeating: "c", count: 64), ImageDescription(text: "gone", source: .auto, language: "en"))
        #expect(try store.sweep() == 1)
    }
}
