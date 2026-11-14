// AT-204 part 2 (R-204 AC7, NFR-D5) — M2.T09: a blob shared by Normal and Evil (or by two packs) is planned and
// fetched once; a blob already in the store is not planned at all.
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct SharedWeightsOnceTests {
    @Test func sharedFilesPlannedOnce() throws {
        let catalog = try SelectorFixtures.baseline()
        let sel = ModelSelector(catalog: catalog).select(profile: try SelectorFixtures.profile("t3-m4max-64"), modes: [.normal, .evil])
        let p = InstallQueue.plan(selection: sel, catalog: catalog, packs: Set(ModelPack.allCases), modes: [.normal, .evil])
        let shas = p.requests.map(\.sha256)
        #expect(shas.count == Set(shas).count)
        // M3.T05 / A-M7-T03c: `stt_multi` (WhisperKit) and `cite_check` (MiniCheck) are fetched on demand, never in a
        // pack install plan.
        let ids = sel.installIDs(packs: Set(ModelPack.allCases), modes: [.normal, .evil], onDemand: ["stt_multi", "cite_check"])
        #expect(p.totalBytes == DownloadSize.bytes(ids: ids, catalog: catalog))
        // Normal and Evil chat share files (tokenizer / preprocessor): counted in Normal's stage only.
        let evilChat = p.stages.first { $0.kind == .evil }?.items.first { $0.pack == .chat }
        let evilModel = try #require(evilChat.flatMap { catalog.models[$0.modelID] })
        let normalSHAs = Set(p.stages.filter { $0.kind != .evil }.flatMap(\.requests).map(\.sha256))
        let shared = evilModel.files.filter { normalSHAs.contains($0.sha256) }
        #expect(!shared.isEmpty)
        #expect(evilChat!.requests.allSatisfy { !normalSHAs.contains($0.sha256) })
        // A blob already present is not planned.
        let present = Set(shared.map(\.sha256))
        let p2 = InstallQueue.plan(selection: sel, catalog: catalog, packs: Set(ModelPack.allCases), modes: [.normal, .evil], present: { present.contains($0) })
        #expect(p2.requests.allSatisfy { !present.contains($0.sha256) })
        #expect(p2.totalBytes == p.totalBytes - shared.reduce(0) { $0 + $1.size })
        ATLog.write("AT-204", "part2.log", "SharedWeightsOnce: \(shas.count) unique files; \(shared.count) Normal/Evil shared files planned once; present blobs skipped")
    }

    @Test func sharedFileFetchedOnceAcrossPacks() async throws {
        let dir = DL.tempDir("shared")
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = try DL.makeBlob(in: dir, name: "tok.bin", size: 3 * TransferConfig.mib)
        let server = try RangeServer(root: dir)
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: nil)
        var r1 = DL.request(blob, server: server); r1.pack = "chat"; r1.modelID = "chat-x"
        var r2 = DL.request(blob, server: server); r2.pack = "evil"; r2.modelID = "evil-x"
        let a = await dl.enqueue(r1)
        let b = await dl.enqueue(r2)
        #expect(a.id == b.id)
        #expect(await dl.wait(a.id)?.state == .done)
        let c = await dl.enqueue(r2)
        #expect(c.state == .done)
        let sent = await server.settledSent(blob.name, atLeast: blob.size)
        #expect(sent == blob.size)
    }
}
