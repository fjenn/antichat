// AT-204 part 2 + AT-NFR-SEC7 (zero-enqueue half) — M2.T09: the install queue order of blueprint E §E.2.4, `chat_fast`
// alone until verified, and nothing enqueued from an expired catalog (or when the disk rule fails).
@testable import AntiChatPlatform
import AntiChatStorage
import Foundation
import Testing

@Suite(.serialized) struct InstallOrderTests {
    let order: [InstallPlan.StageKind] = [.chatFast, .chatEmbed, .voice, .photo, .video, .evil]

    func plan(_ fixture: String, modes: Set<ModelMode> = [.normal, .evil]) throws -> (InstallPlan, Selection, ModelCatalog) {
        let catalog = try SelectorFixtures.baseline()
        let sel = ModelSelector(catalog: catalog).select(profile: try SelectorFixtures.profile(fixture), modes: modes)
        return (InstallQueue.plan(selection: sel, catalog: catalog, packs: Set(ModelPack.allCases), modes: modes), sel, catalog)
    }

    @Test(arguments: ["t1-m1-16", "t2-m4-24", "t3-m4max-64"]) func stageOrder(fixture: String) throws {
        let (p, sel, catalog) = try plan(fixture)
        let kinds = p.stages.map(\.kind)
        #expect(kinds.first == .chatFast)
        #expect(kinds == order.filter(kinds.contains), "\(kinds)")
        // chat_fast stage = the starter only.
        #expect(p.stages[0].items.allSatisfy { $0.role == "chat_fast" && $0.modelID == sel.chatFast?.modelID })
        // Priorities follow the plan order exactly.
        #expect(p.requests.map(\.priority) == Array(0..<p.requests.count))
        // Voice: VAD → STT → TTS.
        if let voice = p.stages.first(where: { $0.kind == .voice }) {
            let roles = voice.items.map { catalog.models[$0.modelID]!.role }
            #expect(roles == roles.sorted { ["vad": 0, "stt": 1, "tts": 2][$0, default: 1] < ["vad": 0, "stt": 1, "tts": 2][$1, default: 1] })
        }
        // Photo carries csam_check when the cell has one; Evil variants come last.
        if p.stages.contains(where: { $0.kind == .evil }) { #expect(p.stages.last?.kind == .evil) }
        ATLog.write("AT-204", "part2.log", "InstallOrder \(fixture): \(kinds.map(\.rawValue).joined(separator: " → ")), \(p.requests.count) files, \(p.totalBytes / 1_000_000) MB unique")
    }

    /// M4.T02 step 1 (D-006): the ChildSafetyCheck detectors install with Photo **or** Video, once (sha256 dedup).
    @Test func detectorsComeWithPhotoOrVideo() throws {
        let catalog = try SelectorFixtures.baseline()
        let sel = ModelSelector(catalog: catalog).select(profile: try SelectorFixtures.profile("t3-m4max-64"), modes: [.normal])
        func items(_ packs: Set<ModelPack>) -> [InstallPlan.Item] {
            InstallQueue.plan(selection: sel, catalog: catalog, packs: packs, modes: [.normal]).stages.flatMap(\.items)
        }
        let detectors: Set<String> = ["csc-nudity", "csc-age", "csc-age-bins"]
        #expect(detectors.isSubset(of: Set(items([.chat, .photo]).map(\.modelID))))
        #expect(detectors.isSubset(of: Set(items([.chat, .video]).map(\.modelID))))
        // Both packs list the detectors, but their files download once (dedup by sha256).
        let reqs = items([.chat, .photo, .video]).filter { detectors.contains($0.modelID) }.flatMap(\.requests)
        #expect(reqs.count == Set(reqs.map(\.sha256)).count && !reqs.isEmpty)
        #expect(items([.chat, .voice]).allSatisfy { !detectors.contains($0.modelID) })
    }

    @Test func chatFastAloneUntilVerified() async throws {
        let dir = DL.tempDir("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try DL.makeBlob(in: dir, name: "fast.bin", size: 8 * TransferConfig.mib, seed: 11)
        let b = try DL.makeBlob(in: dir, name: "chat.bin", size: 2 * TransferConfig.mib, seed: 12)
        let c = try DL.makeBlob(in: dir, name: "embed.bin", size: 2 * TransferConfig.mib, seed: 13)
        let server = try RangeServer(root: dir, args: ["--slow", "4000"])
        let dl = DownloadCoordinator(models: ModelsDirectory(root: dir.appending(path: "Models")), database: nil,
                                     config: TransferConfig(chunkSize: 2 * TransferConfig.mib))
        let log = Notices()
        dl.observe { if case .state(let j) = $0 { log.add("\(j.request.modelID ?? "?"):\(j.state.rawValue)") } }
        func req(_ blob: DL.Blob, _ id: String, _ prio: Int) -> DownloadRequest {
            var r = DL.request(blob, server: server); r.modelID = id; r.priority = prio; return r
        }
        let p = InstallPlan(stages: [
            .init(kind: .chatFast, items: [.init(modelID: "fast", pack: .chat, mode: .normal, role: "chat_fast", requests: [req(a, "fast", 0)])]),
            .init(kind: .chatEmbed, items: [.init(modelID: "chat", pack: .chat, mode: .normal, role: "chat", requests: [req(b, "chat", 1)]),
                                            .init(modelID: "embed", pack: .chat, mode: .normal, role: "embed", requests: [req(c, "embed", 2)])]),
        ])
        #expect(await InstallQueue.run(p, coordinator: dl, mayInstallNew: true, free: 500_000_000_000) == .enqueued(jobs: 3))
        await dl.waitForIdle()
        let events = log.all.compactMap { $0 }
        let fastDone = try #require(events.firstIndex(of: "fast:done"))
        let firstOther = try #require(events.firstIndex { $0.hasPrefix("chat:") || $0.hasPrefix("embed:") })
        #expect(firstOther > fastDone, "\(events)")
        #expect(await dl.allJobs.allSatisfy { $0.state == .done })
    }

    /// AT-NFR-SEC7 (zero-enqueue half): an expired catalog keeps installed models but enqueues nothing new.
    @Test func testExpiredCatalogEnqueuesNothing() async throws {
        let server = FixtureServer()
        server.serve(try CatalogFixtures.pair("catalog-expired"))
        let store = CatalogStore.fixture(server: server, cache: CatalogFixtures.tempDir())
        #expect(await store.refresh() == .expired)
        let (p, _, _) = try plan("t1-m1-16", modes: [.normal])
        #expect(!p.isEmpty)
        let dl = DownloadCoordinator(models: ModelsDirectory(root: DL.tempDir("sec7")), database: try AppDatabase.inMemory())
        #expect(await InstallQueue.run(p, coordinator: dl, mayInstallNew: store.mayInstallNew, free: 500_000_000_000) == .catalogRefused)
        #expect(await dl.allJobs.isEmpty)
        ATLog.write("AT-NFR-SEC7", "zero-enqueue.log", "expired catalog (v\(store.catalog?.catalogVersion ?? 0)): mayInstallNew=false → InstallQueue.run → catalogRefused, 0 download jobs (plan had \(p.requests.count) files)")
    }

    @Test func diskShortEnqueuesNothing() async throws {
        let (p, _, _) = try plan("t1-m1-16", modes: [.normal])
        let dl = DownloadCoordinator(models: ModelsDirectory(root: DL.tempDir("short")), database: nil)
        let out = await InstallQueue.run(p, coordinator: dl, mayInstallNew: true, free: p.totalBytes + 9_000_000_000)
        #expect(out == .diskShort(gbNeeded: 1))
        #expect(await dl.allJobs.isEmpty)
    }
}
