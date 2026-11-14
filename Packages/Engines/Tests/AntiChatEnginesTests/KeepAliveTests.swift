// AT-206 part 1 AC4 + AT-NFR-M2 unit leg (M2.T12 step 5): a virtual clock drives keep-alive — chat 5 / 15 / 30 min /
// Never from the Advanced setting (default 15 on AC), 5 min on battery / Low Power, voice 5 min, embeddings 2 min,
// never while the app is frontmost with a chat open; a held lease never expires.
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct KeepAliveTests {
    func chatUnloadsAfter(keepAlive: Int, lowPower: Bool = false, frontmost: Bool = false, horizon: Double = 3600) async throws -> Double? {
        let clock = ManualClock()
        let s = ModelScheduler(loader: FakeLoader(), clock: clock.fn)
        await s.setPolicy(Synth.policy(16, keepAlive: keepAlive, lowPower: lowPower, frontmost: frontmost))
        let l = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat", 6)); await s.release(l)
        var t = 0.0
        while t <= horizon {
            if await s.releaseIdle().contains("chat") { return t }
            clock.advance(5); t += 5
        }
        return nil
    }

    @Test(arguments: [(300, 300.0), (900, 900.0), (1800, 1800.0)])
    func chatFollowsTheSetting(_ setting: Int, _ expected: Double) async throws {
        #expect(try await chatUnloadsAfter(keepAlive: setting) == expected)
    }

    @Test func neverMeansStillResidentAfterAnHour() async throws {
        #expect(try await chatUnloadsAfter(keepAlive: 0) == nil)
    }

    @Test func batteryShortensToFiveMinutes() async throws {
        #expect(try await chatUnloadsAfter(keepAlive: 900, lowPower: true) == 300)
        #expect(try await chatUnloadsAfter(keepAlive: 0, lowPower: true) == nil, "Never stays never")
    }

    @Test func frontmostWithAChatOpenNeverUnloads() async throws {
        #expect(try await chatUnloadsAfter(keepAlive: 300, frontmost: true) == nil)
    }

    @Test func voiceFiveMinutesEmbeddingsTwoAndLeasesHold() async throws {
        let clock = ManualClock()
        let s = ModelScheduler(loader: FakeLoader(), capacity: Synth.unlimited, clock: clock.fn)
        await s.setPolicy(Synth.policy(16))
        for (k, r) in [("stt", ResidencyRole.stt), ("embed", .embed)] {
            let l = try await s.ensureLoaded(role: r, model: Synth.slot(k, 0.5)); await s.release(l)
        }
        let held = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat", 6))
        clock.advance(119); #expect(await s.releaseIdle().isEmpty)
        clock.advance(1); #expect(await s.releaseIdle() == ["embed"])
        clock.advance(180); #expect(await s.releaseIdle() == ["stt"])
        clock.advance(7200); #expect(await s.releaseIdle().isEmpty, "a held lease never expires")
        await s.release(held)
    }

    @Test func scaledClockForTheRealRun() {
        // SetPolicy.testClockScale (Debug) decodes and defaults off; older senders omit it.
        let json = #"{"budgetB":1,"keepAliveSeconds":300,"lowPower":false,"batch":{"windowMS":16,"maxTokens":8}}"#
        let p = try? JSONDecoder().decode(SetPolicy.self, from: Data(json.utf8))
        #expect(p != nil && p?.testClockScale == nil && p?.allowOverBudget == false && p?.lowTier == true)
        #expect(KeepAlive.timeout(.chat, KeepAlivePolicy(chatSeconds: 900)) == 900)
        #expect(KeepAlive.timeout(.image, KeepAlivePolicy(lowTier: true)) == 0)
    }
}
