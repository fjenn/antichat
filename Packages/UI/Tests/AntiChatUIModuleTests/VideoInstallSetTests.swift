// M5 review P1-1: a fresh install of the Video pack (the bundled signed catalog, the selector's install set — no dev
// model cache) carries the TAEHV weights the Wan2.2 jobs need, and the requests InstalledVideoModels builds from those
// install views have a TAEHV path for T2V (vid-5b, Normal and Evil) and I2V; without it there is no request
// (unavailable), never a job that fails `taehvMissing` in the runtime.
// fix/t4-video (A-M5-13): on a T4 Mac too (the 128 GB and the 96 GB cell) the plan card's default text-to-video job
// resolves to a complete request (vid-5b + TAEHV + runtime) in Normal and Evil chats, and Sound on (Normal) to vid-ltx;
// T4 text-to-video is never `unavailable` on a real install.
//   make test-unit FILTER=VideoInstallSetTests
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatPlatform
import Foundation
import Testing
@testable import AntiChatUI

@MainActor @Suite(.isolatedSettings) struct VideoInstallSetTests {
    static let catalog: ModelCatalog = try! ModelCatalog.decode(CatalogStore.bundledBaseline()!.data)

    static func profile(_ fixture: String) throws -> HardwareProfile {
        let url = try #require(HardwareProbe.fixtureURL(fixture))
        let facts = try HardwareFacts(fixture: Data(contentsOf: url))
        return HardwareProfile(facts: facts, classification: TierClassifier.classify(facts: facts), fixture: fixture)
    }

    /// The Video pack's install set on a T2 and a T3 Mac, Normal and Evil, includes `vid-taehv` (the catalog entry
    /// with a real commit-pinned source) wherever a Wan2.2 model (vid-5b / vid-i2v) is installed.
    @Test(arguments: ["t2-m4-24", "t3-m4pro-48"])
    func freshVideoInstallIncludesTAEHV(fixture: String) throws {
        let selection = ModelSelector(catalog: Self.catalog).select(profile: try Self.profile(fixture), modes: [.normal, .evil])
        for mode in [ModelMode.normal, .evil] {
            let ids = selection.installIDs(packs: [.video], modes: [mode])
            #expect(ids.contains("vid-5b") && ids.contains("vid-i2v"), "\(fixture)/\(mode): \(ids.sorted())")
            #expect(ids.contains("vid-taehv"), "\(fixture)/\(mode): \(ids.sorted())")
        }
        let taehv = try #require(Self.catalog.models["vid-taehv"])
        let file = try #require(taehv.files.first { $0.path.hasSuffix("taew2_2.safetensors") })
        #expect(file.sha256 == "b84609b2a133d48434bd9636bfcb44bf05168dc436e2d3cecf26256faa1f5325" && file.size == 22_848_048)
        #expect(file.sources.first?.hasPrefix("https://raw.githubusercontent.com/madebyollin/taehv/\(taehv.commit)/") == true)
    }

    /// Install views laid out from the catalog's file lists (empty files): the resolved requests carry TAEHV.
    @Test func requestsFromAFreshInstallCarryTAEHV() throws {
        let installs = FileManager.default.temporaryDirectory.appendingPathComponent("video-installs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: installs) }
        let ids = ModelSelector(catalog: Self.catalog).select(profile: try Self.profile("t3-m4pro-48"), modes: [.normal, .evil])
            .installIDs(packs: [.video], modes: [.normal, .evil])
        for id in ids {
            for f in Self.catalog.models[id]?.files ?? [] {
                let u = installs.appendingPathComponent(id).appendingPathComponent(f.path)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: u.path, contents: Data())
            }
        }
        let runtime = installs.appendingPathComponent("video-runtime@0.1.0")
        func job(_ intent: VideoPlanPolicy.Intent, source: String?, evil: Bool = false) throws -> VideoPlanJob {
            let input = VideoPlanInput(prompt: "waves at dusk", intent: intent, sourceImageID: source, isEvil: evil, tier: "T3",
                                       speedClass: "S4", budgetGB: 48, models: VideoPlanCardPreview.models, sound: false)
            return try #require(VideoPlan.make(input).job)
        }
        func request(_ j: VideoPlanJob, evil: Bool, source: String? = nil) -> VideoRequest? {
            InstalledVideoModels.request(j, sourceImagePath: source, seed: 1, isEvil: evil, catalog: Self.catalog, installs: installs,
                                         runtime: runtime, budget: 48_000_000_000)
        }
        let t2v = try job(.createVideoChip, source: nil)
        #expect(t2v.spec.model == "vid-5b")
        for evil in [false, true] {
            let r = try #require(request(t2v, evil: evil), "T2V evil=\(evil)")
            #expect(r.taehv.hasSuffix("vid-taehv/safetensors/taew2_2.safetensors"))
            #expect(FileManager.default.fileExists(atPath: r.taehv))
        }
        let i2v = try job(.animate, source: "a1")
        let r = try #require(request(i2v, evil: false, source: "/m/src.png"), "I2V")
        #expect(r.mode == .i2v && r.taehv.hasSuffix("taew2_2.safetensors") && !r.diffusionModel.isEmpty)

        // Without the TAEHV install view: unavailable (nil), not a request with an empty path.
        try FileManager.default.removeItem(at: installs.appendingPathComponent("vid-taehv"))
        #expect(request(t2v, evil: false) == nil)
        #expect(request(i2v, evil: false, source: "/m/src.png") == nil)
    }

    /// Install views laid out from the catalog's file lists (empty files).
    static func layOut(_ ids: Set<String>) throws -> URL {
        let installs = FileManager.default.temporaryDirectory.appendingPathComponent("video-installs-\(UUID().uuidString)")
        for id in ids {
            for f in Self.catalog.models[id]?.files ?? [] {
                let u = installs.appendingPathComponent(id).appendingPathComponent(f.path)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: u.path, contents: Data())
            }
        }
        return installs
    }

    /// T4 (fix/t4-video, A-M5-13): a fresh install's Video set, Normal and Evil, resolves the plan card's default
    /// text-to-video job — through the same VideoPlanInput (profile init) and InstalledVideoModels path the app uses —
    /// to a complete request: vid-5b's model dir, the TAEW2.2 decoder and the runtime. Sound on (Normal) → vid-ltx.
    @Test(arguments: ["t4-m5max-128", "t4-m3max-96"])
    func freshT4InstallResolvesTextToVideo(fixture: String) throws {
        let profile = try Self.profile(fixture)
        #expect(profile.tier == .T4)
        let selection = ModelSelector(catalog: Self.catalog).select(profile: profile, modes: [.normal, .evil])
        for mode in [ModelMode.normal, .evil] {
            let ids = selection.installIDs(packs: [.video], modes: [mode])
            #expect(ids.isSuperset(of: ["vid-5b", "vid-taehv", "vid-i2v"]), "\(fixture)/\(mode): \(ids.sorted())")
            #expect(!ids.contains("vid-14b"), "\(fixture)/\(mode): vid-14b is not a T4 model (A-M5-13)")
        }
        #expect(selection.installIDs(packs: [.video], modes: [.normal]).contains("vid-ltx"), "T3+ Sound (M5.T07) on T4 too")
        let installs = try Self.layOut(selection.installIDs(packs: [.video], modes: [.normal, .evil]))
        defer { try? FileManager.default.removeItem(at: installs) }
        let runtime = installs.appendingPathComponent("video-runtime@0.3.2")
        for evil in [false, true] {
            let input = VideoPlanInput(prompt: "waves at dusk", intent: .createVideoChip, isEvil: evil, profile: profile,
                                       selection: selection, catalog: Self.catalog)
            #expect(input.tier == "T4")
            let job = try #require(VideoPlan.make(input).job, "\(fixture) evil=\(evil): no plan job")
            #expect(job.spec.model == "vid-5b", "\(fixture) evil=\(evil): \(job.spec.model)")
            // The T4 default preset: 720p Medium = Wan2.2-TI2V-5B's native 1280×704 × 121 frames at 24 fps.
            #expect(job.spec.width == 1280 && job.spec.height == 704 && job.spec.frames == 121 && job.spec.fps == 24)
            let r = try #require(InstalledVideoModels.request(job, sourceImagePath: nil, seed: 1, isEvil: evil, catalog: Self.catalog,
                                                              installs: installs, runtime: runtime, budget: 128_000_000_000),
                                 "\(fixture) evil=\(evil): unavailable")
            #expect(r.mode == .t2v && r.runtimeDir == runtime.path && r.modelKind == nil)
            #expect(r.modelDir == installs.appendingPathComponent("vid-5b").path)
            #expect(r.taehv.hasSuffix("vid-taehv/safetensors/taew2_2.safetensors") && FileManager.default.fileExists(atPath: r.taehv))
            #expect(r.footprintBytes > 0 && r.memoryLimitBytes == 128_000_000_000)
        }
        // Sound on in a Normal chat → the LTX job (T3+, K-014); Evil chats never get it.
        let sound = VideoPlanInput(prompt: "waves at dusk", intent: .createVideoChip, isEvil: false, profile: profile,
                                   selection: selection, catalog: Self.catalog, sound: true)
        let ltx = try #require(VideoPlan.make(sound).job)
        #expect(ltx.spec.model == "vid-ltx")
        let lr = try #require(InstalledVideoModels.request(ltx, sourceImagePath: nil, seed: 1, isEvil: false, catalog: Self.catalog,
                                                           installs: installs, runtime: runtime, budget: 128_000_000_000))
        #expect(lr.modelKind == "ltx" && lr.gemmaDir?.isEmpty == false)
    }
}
