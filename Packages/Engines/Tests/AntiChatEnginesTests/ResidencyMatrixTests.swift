// AT-206 part 1 (R-206 AC2 resident part, NFR-R4; M2.T12 step 6): on every tier fixture the chat model, the embedding
// model and the voice set stay resident together within B; a media job evicts by E.2.7 and the job model does not
// stay resident afterwards on T0–T2; the idle signal (T11/T13) follows leases and the active job.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct ResidencyMatrixTests {
    @Test(arguments: Synth.tierB.map(\.tier))
    func chatEmbedAndVoiceResidentOnEveryTier(_ tier: String) async throws {
        let t = Synth.tierB.first { $0.tier == tier }!
        let s = ModelScheduler(loader: FakeLoader(), capacity: Synth.unlimited, clock: ManualClock().fn)
        let low = ["T0", "T1", "T2-24"].contains(tier)
        await s.setPolicy(Synth.policy(t.b, lowTier: low))
        for (k, gb, role) in [("embed", 0.4, ResidencyRole.embed), ("stt", 0.7, .stt), ("tts", 0.25, .tts), ("chat", t.chat, .chat)] {
            let l = try await s.ensureLoaded(role: role, model: Synth.slot(k, gb)); await s.release(l)
        }
        #expect(await s.residentKeys == ["chat", "embed", "stt", "tts"])
        #expect(await s.usedBytes <= UInt64(t.b * Synth.GB))
        // An image job (2.8 GB) makes room by E.2.7; the job model is not resident afterwards on T0–T2.
        let img = Synth.slot("img", 2.8)
        try await s.runJob(key: "img") { ctx in
            _ = await ctx.makeRoom(bytes: img.footprintBytes, role: .image)
            let used = await ctx.resident().reduce(UInt64(0)) { $0 + $1.bytes }
            #expect(used + img.footprintBytes <= UInt64(t.b * Synth.GB))
        }
        #expect(await s.activeJob == nil)
        let lj = try await s.ensureLoaded(role: .image, model: img); await s.release(lj)
        await s.releaseIdle()
        if low { #expect(!(await s.residentKeys.contains("img")), "NFR-R4: no image model resident without a job on \(tier)") }
        let resident = Set(await s.resident.map(\.role))
        #expect(resident.isSubset(of: [.chat, .embed, .stt, .tts, .image]))
    }

    @Test func idleSignalFollowsLeasesAndJobs() async throws {
        let s = ModelScheduler(loader: FakeLoader(), capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(16))
        let l = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat", 6))
        #expect(await !s.isIdle(pack: "chat"))
        #expect(await s.isIdle(pack: "voice"))
        await s.release(l)
        #expect(await s.isIdle(pack: "chat"))
        try await s.runJob(key: "img") { ctx in
            #expect(await ctx.scheduler.activeJob == "img")
            #expect(await !ctx.scheduler.isIdle(pack: "chat"))
        }
        #expect(await s.isIdle(pack: "chat"))
    }
}
