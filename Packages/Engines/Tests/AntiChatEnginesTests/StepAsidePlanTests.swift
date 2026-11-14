// AT-206 part 2, unit leg (R-206 AC2; M2.T13 step 1; Atomic-Chat@29b01d8 arbiter order): a media job that does not fit
// beside the chat model makes it step aside (its KV prefix snapshotted first), keeps embeddings when they fit and
// evicts voice last; on T3 the job co-resides. A leased model never goes. FeatureFlag.mediaStepAside off = the LLM
// always goes. Footprints: ScriptedImageEngine 6.5 GB; chat per tier fixture (Synth.tierB).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct StepAsidePlanTests {
    static let media = UInt64(6.5 * Synth.GB)

    func entry(_ k: String, _ gb: Double, _ role: ResidencyRole, used: Double = 0, refs: Int = 0) -> ResidentEntry {
        ResidentEntry(slot: Synth.slot(k, gb), role: role, bytes: UInt64(gb * Synth.GB), refCount: refs, lastUsed: used)
    }

    @Test func t1ChatStepsAsideEmbeddingsStay() {
        let p = StepAside.plan(entries: [entry("chat-9b-q4", 6.5, .chat), entry("embed", 0.6, .embed)], mediaBytes: Self.media,
                               budget: UInt64(9.5 * Synth.GB))
        #expect(p.victims == ["chat-9b-q4"] && p.chatVictims == ["chat-9b-q4"] && p.fits)
    }

    @Test func t2ChatGoesSearchAndVoiceStay() {
        let es = [entry("chat-9b", 11.0, .chat), entry("embed", 0.6, .embed), entry("stt", 0.6, .stt), entry("tts", 0.4, .tts)]
        let p = StepAside.plan(entries: es, mediaBytes: Self.media, budget: UInt64(16 * Synth.GB))
        #expect(p.victims == ["chat-9b"] && p.fits)
    }

    @Test func voiceIsEvictedLast() {
        let es = [entry("stt", 1, .stt), entry("tts", 1, .tts), entry("embed", 0.6, .embed), entry("chat", 2, .chat)]
        let p = StepAside.plan(entries: es, mediaBytes: Self.media, budget: UInt64(8 * Synth.GB))
        #expect(p.victims == ["chat", "embed", "tts"], "chat → search → TTS; STT stays")
    }

    @Test func t3CoResidesWithoutEviction() {
        let p = StepAside.plan(entries: [entry("chat-35b", 21.5, .chat), entry("embed", 0.6, .embed)], mediaBytes: Self.media,
                               budget: UInt64(36 * Synth.GB))
        #expect(p.victims.isEmpty && p.fits)
    }

    @Test func leasedChatNeverStepsAside() {
        let p = StepAside.plan(entries: [entry("chat", 6.5, .chat, refs: 1)], mediaBytes: Self.media, budget: UInt64(9.5 * Synth.GB))
        #expect(p.victims.isEmpty && !p.fits)
    }

    @Test func flagOffAlwaysUnloadsTheLLM() {
        let p = StepAside.plan(entries: [entry("chat-35b", 21.5, .chat), entry("embed", 0.6, .embed)], mediaBytes: Self.media,
                               budget: UInt64(36 * Synth.GB), stepAside: false)
        #expect(p.victims == ["chat-35b"] && p.chatVictims == ["chat-35b"])
    }

    /// Through the scheduler's job queue: snapshot, then unload (fake loader).
    @Test func jobContextSnapshotsBeforeUnload() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(9.5))
        let t = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b-q4", 6.5))
        await s.release(t)
        let e = try await s.ensureLoaded(role: .embed, model: Synth.slot("embed", 0.6))
        await s.release(e)
        // Order only: with the fake loader nothing here takes time, so a wall-clock bar measured the host's load, not
        // the step-aside (NFR-M3's 1 s is measured on real models by the AT, not here).
        let gone = try await s.runJob(key: "img") { ctx in await ctx.stepAside(bytes: Self.media) }
        #expect(gone.map(\.key) == ["chat-9b-q4"])
        #expect(loader.events.suffix(2) == ["snapshot chat-9b-q4", "unload chat-9b-q4"])
        #expect(await s.residentKeys == ["embed"])
    }
}

/// M2.T13 DoD: a KV prefix snapshot is never written for an incognito chat.
@Suite struct KVSnapshotIncognitoTests {
    @Test func incognitoSessionsAreNeverPersistable() {
        let c = MLXPrefixCache()
        let normal = UUID(), incognito = UUID()
        c.storeSession(normal, tokens: [1, 2, 3], cache: [], state: nil)
        c.markIncognito(incognito)
        c.storeSession(incognito, tokens: [4, 5], cache: [], state: nil)
        #expect(c.persistableSessions().map(\.0) == [normal])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kv-\(UUID().uuidString)")
        _ = PromptCacheSnapshot.save(c, model: "m", to: dir)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(!files.contains { $0.hasPrefix(incognito.uuidString) })
    }

    /// M9.T05: a stable prefix an incognito request built is never persistable; a normal one is.
    @Test func incognitoPrefixesAreNeverPersistable() {
        let c = MLXPrefixCache()
        c.storePrefix("normal-key", tokens: [1, 2, 3], cache: [], state: nil)
        c.storePrefix("incognito-key", tokens: [1, 2], cache: [], state: nil, incognito: true)
        #expect(c.persistablePrefixes().map(\.0) == ["normal-key"])
    }

    /// M9.T05: prefix files are per model by name, another model's fresh file is left alone, and any prefix file a day
    /// old is removed (its date line no longer matches anything).
    @Test func prefixFilesAreModelTaggedAndExpireAfterADay() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = PromptCacheSnapshot.prefixURL(dir, model: "my-model", key: "k1")
        let other = PromptCacheSnapshot.prefixURL(dir, model: "other-model", key: "k1")
        #expect(mine != other)
        #expect(mine.lastPathComponent.hasPrefix(PromptCacheSnapshot.prefixFilePrefix))
        try Data("x".utf8).write(to: other)
        try Data("x".utf8).write(to: mine)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: mine.path)
        // Session restore ignores prefix files (not a session UUID).
        #expect(PromptCacheSnapshot.restore(into: MLXPrefixCache(), model: "my-model", from: dir).isEmpty)
        #expect(PromptCacheSnapshot.restorePrefixes(into: MLXPrefixCache(), model: "my-model", from: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: mine.path), "a day-old prefix file is removed")
        #expect(FileManager.default.fileExists(atPath: other.path), "another model's fresh prefix file stays")
    }
}

/// M2 review #11: a memory-pressure release during a media job runs beside the job's own step-aside; both used to
/// pass `entries[key]` before their awaits, so `loader.unload` ran twice for the same slot.
@Suite struct PressureDuringJobTests {
    final class SlowUnloadLoader: ResidencyLoader, @unchecked Sendable {
        private let lock = NSLock()
        private var _unloads: [String: Int] = [:]
        var unloads: [String: Int] { lock.withLock { _unloads } }
        func load(_ slot: ModelSlot) async throws -> Double { 0.01 }
        func unload(_ slot: ModelSlot) async {
            lock.withLock { _unloads[slot.key, default: 0] += 1 }
            try? await Task.sleep(for: .milliseconds(100))
        }
        func measuredBytes(_ slot: ModelSlot) async -> UInt64 { 0 }
        func isAlive(_ slot: ModelSlot) async -> Bool { true }
        func apply(budget: UInt64) async {}
        func snapshotKV(_ slot: ModelSlot) async {}
    }

    @Test func pressureAndStepAsideUnloadOnce() async throws {
        let loader = SlowUnloadLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited, clock: ManualClock().fn)
        await s.setPolicy(Synth.policy(9.5))
        let t = try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-9b-q4", 6.5))
        await s.release(t)
        try await s.runJob(key: "img") { ctx in
            async let aside = ctx.stepAside(bytes: StepAsidePlanTests.media)
            try? await Task.sleep(for: .milliseconds(20))  // the step-aside's unload is in flight
            async let pressure = s.releaseForPressure(.warning)
            _ = await (aside, pressure)
        }
        #expect(loader.unloads["chat-9b-q4"] == 1, "\(loader.unloads)")
        #expect(await s.residentKeys.isEmpty)
    }
}

/// Shared caches (the kv folder and the detectors' compiled cache are used by every helper on these caches — a second
/// app instance, test hosts of other checkouts): another model's / set's files are not deleted while they may be in use.
@Suite struct SharedCacheSweepTests {
    @Test func anotherModelsSnapshotSurvivesARestoreUntilItIsADayOld() throws {
        let c = MLXPrefixCache()
        let s = UUID()
        c.storeSession(s, tokens: [1, 2, 3], cache: [], state: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = PromptCacheSnapshot.save(c, model: "other-helper-model", to: dir)
        try #require(saved == [s])
        let file = PromptCacheSnapshot.url(dir, session: s)
        #expect(PromptCacheSnapshot.restore(into: MLXPrefixCache(), model: "my-model", from: dir).isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path), "a fresh snapshot of another model stays")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: file.path)
        _ = PromptCacheSnapshot.restore(into: MLXPrefixCache(), model: "my-model", from: dir)
        #expect(!FileManager.default.fileExists(atPath: file.path), "a day-old one is discarded")
    }

    @Test func anotherDetectorSetIsKeptUntilAWeekUnused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("csc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent(MediaOutputGate.preparedMarker)
        try Data("{}".utf8).write(to: marker)
        #expect(!MediaOutputGate.untouched(dir, for: MediaOutputGate.otherSetsKeptFor), "prepared just now: kept")
        let old = Date().addingTimeInterval(-8 * 86_400)
        for u in [marker, dir] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: u.path) }
        #expect(MediaOutputGate.untouched(dir, for: MediaOutputGate.otherSetsKeptFor), "unused for 8 days: may go")
    }
}
