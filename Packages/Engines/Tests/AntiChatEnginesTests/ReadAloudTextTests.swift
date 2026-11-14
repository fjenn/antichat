// M3.T07 (R-054 AC2, R-282 AC1): SpeakableTextTests (fixture Markdown with headings, lists, bold, links, a table and
// three code fences → no Markdown symbol reaches the synthesiser; each fence → exactly one "code omitted"),
// ClauseChunkerTests (first chunk ≥ 4 words at the first eligible clause; streaming token by token equals batch;
// 240-char cap), ChunkTableTests (source ranges, word offsets, spoken offset) and KokoroBackend / TTSService with a
// synthesiser double on the silent clock (order of starts, stop ≤ 200 ms, Kokoro path chosen with the pack).
//   make test-unit FILTER='SpeakableTextTests|ClauseChunkerTests|ChunkTableTests|KokoroBackendTests'
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing

@testable import AntiChatEngines

struct SpeakableTextTests {
    static let fixture = """
        # Release notes

        Here is **what changed** in _this_ build, see [the docs](https://example.com/docs) or https://www.apple.com/macos/.

        - First item with `inline code`
        - Second item
        1. Numbered

        > A quoted line.

        ```swift
        let x = 1 // # not a heading
        print(x) | y
        ```

        | Name | Value |
        |------|-------|
        | a    | 1     |

        Then a second block:

        ~~~
        echo "*"
        ~~~

        And the last one, left open while streaming:

        ```python
        print("hi")
        """

    @Test func noMarkdownSymbolIsSpokenAndEachFenceIsOneCodeOmitted() {
        let s = SpeakableText.from(markdown: Self.fixture)
        #expect(!s.contains { SpeakableText.forbidden.contains($0) }, "\(s)")
        #expect(s.components(separatedBy: "code omitted").count - 1 == 3, "\(s)")
        #expect(s.contains("Release notes") && s.contains("what changed") && s.contains("the docs"))
        #expect(s.contains("apple.com") && !s.contains("https"), "URLs → host: \(s)")
        #expect(!s.contains("Value") && !s.contains("print"), "tables and code are not read: \(s)")
        #expect(s.contains("inline code") && s.contains("A quoted line."))
    }

    @Test func localizedCodeOmitted() {
        let s = SpeakableText.from(markdown: "Look:\n\n```\nx\n```\n", codeOmitted: "Code ausgelassen")
        #expect(s.hasSuffix("Code ausgelassen."), "\(s)")
    }
}

struct ClauseChunkerTests {
    static let reply = "Sure, here is the plan for today: we start early, then we test the build. After lunch we write the "
        + "report and send it. Finally, we review everything!\nA list item without a stop\nThe end."

    @Test func firstChunkIsTheFirstClauseWithFourWords() {
        let c = ClauseChunker.chunks(Self.reply)
        // "Sure," has one word: not eligible; no clause mark follows within 5 words, so the first chunk is cut after
        // 5 words (NFR-V1, ≥ 4 words: R-282 AC1); later chunks are sentences.
        #expect(c.first == "Sure, here is the plan", "\(c)")
        #expect(c.first!.split(separator: " ").count >= 4)
        #expect(c[1] == "for today: we start early, then we test the build.", "later chunks are sentences: \(c)")
        #expect(c.contains("A list item without a stop"))
        #expect(c.last == "The end.")
    }

    @Test func aShortFirstSentenceIsTheFirstChunk() {
        #expect(ClauseChunker.chunks("Yes. It works, and it is fast.").first == "Yes.")
    }

    @Test func streamingTokenByTokenEqualsBatch() {
        let batch = ClauseChunker.chunks(Self.reply)
        for step in [1, 2, 3, 7] {
            var c = ClauseChunker()
            var out: [String] = []
            var i = Self.reply.startIndex
            while i < Self.reply.endIndex {
                let j = Self.reply.index(i, offsetBy: step, limitedBy: Self.reply.endIndex) ?? Self.reply.endIndex
                out += c.feed(String(Self.reply[i..<j]))
                i = j
            }
            out += c.finish()
            #expect(out == batch, "step \(step)")
        }
    }

    @Test func longSentencesAreCappedAtTwoHundredFortyCharacters() {
        let long = "word " + String(repeating: "alpha beta gamma delta, ", count: 20) + "end."
        let c = ClauseChunker.chunks("Okay. " + long)
        #expect(c.allSatisfy { $0.count <= ClauseChunker.maxChars }, "\(c.map(\.count))")
        #expect(c.joined(separator: " ").replacingOccurrences(of: " ", with: "") == ("Okay. " + long).replacingOccurrences(of: " ", with: ""))
    }
}

struct ChunkTableTests {
    @Test func rangesPointIntoTheStoredMarkdownAndTrackPlayedWords() {
        let md = "## Plan\n\nWe **start** early, then test.\n\n```\ncode\n```\n\nDone now."
        var t = ChunkTable(source: md)
        let chunks = ClauseChunker.chunks(SpeakableText.from(markdown: md))
        #expect(chunks == ["Plan", "We start early, then test.", "code omitted.", "Done now."], "\(chunks)")
        for (i, c) in chunks.enumerated() { t.append(index: i, text: c, samples: 24_000) }
        let ns = md as NSString
        #expect(ns.substring(with: NSRange(t.entries[1].textRange)) == "We **start** early, then test")
        #expect(t.entries[2].textRange.isEmpty, "code omitted maps to no stored words")
        #expect(ns.substring(with: NSRange(t.entries[3].textRange)) == "Done now")
        #expect(t.entries[1].wordOffsets.count == 5 && t.entries[1].wordOffsets.first == 0)
        #expect(zip(t.entries[1].wordOffsets, t.entries[1].wordOffsets.dropFirst()).allSatisfy { $0 < $1 })
        let mid = t.spokenOffset(chunk: 1, playedSamples: 12_000)!
        #expect(mid > t.entries[1].textRange.lowerBound && mid < t.entries[1].textRange.upperBound)
        #expect(t.spokenOffset(chunk: 1, playedSamples: 24_000) == t.entries[1].textRange.upperBound)
    }
}

/// A synthesiser double: 0.1 s of audio per word at 24 kHz, `delay` of synthesis per chunk.
final class FakeSynth: SpeechSynthesizing, @unchecked Sendable {
    let name = "fake"
    let delay: Duration
    let texts = Mutex<[String]>([])
    init(delay: Duration = .milliseconds(5)) { self.delay = delay }
    func synthesize(_ text: String) async throws -> SynthesizedAudio {
        texts.withLock { $0.append(text) }
        try await Task.sleep(for: delay)
        return SynthesizedAudio(samples: [Float](repeating: 0.01, count: 2_400 * max(1, text.split(separator: " ").count)), sampleRate: 24_000)
    }
}

struct KokoroBackendTests {
    static func chunks(_ xs: [String]) -> AsyncStream<TTSChunk> {
        AsyncStream { c in
            for (i, x) in xs.enumerated() { c.yield(TTSChunk(index: i, text: x)) }
            c.finish()
        }
    }

    @Test func chunksStartInOrderAndFinish() async {
        let b = KokoroBackend(tts: FakeSynth(), output: .silent)
        let synthesized = Mutex<[Int]>([])
        b.onSynthesized = { c, n in synthesized.withLock { $0.append(n) }; _ = c }
        var starts: [Int] = []
        var finished: Bool?
        for await e in b.speak(Self.chunks(["One two three four,", "five six.", "Seven."]), voice: "", rate: 1) {
            switch e {
            case .started(let i): starts.append(i)
            case .finished(let s): finished = s
            case .played: break
            }
        }
        #expect(starts == [0, 1, 2])
        #expect(finished == false)
        #expect(synthesized.withLock { $0 } == [9_600, 4_800, 2_400])
    }

    /// R-054 AC1: the interval measured is the stop itself — from `stop()` to the output being silent and the reply
    /// reported finished — not the test task's own scheduling around it (the former `now - t0 < 2 s` also counted
    /// the stream's start and a 100 ms sleep, and a loaded host stretched those to 2.04 s while the stop took < 200 ms;
    /// the finish used to wait for the speech task's next 10 ms poll to be scheduled, now `stop()` sends it).
    @Test func stopEndsWithinTwoHundredMilliseconds() async throws {
        let b = KokoroBackend(tts: FakeSynth(), output: .silent)
        // 30 s of audio: the reply is still playing when the stop comes however long the host takes to get there.
        let words = Array(repeating: "word", count: 300).joined(separator: " ")
        var stoppedAt: ContinuousClock.Instant?
        var silentAfter: Duration?
        var finishedAfter: Duration?
        var finished: Bool?
        var playedMs: Double?
        for await e in b.speak(Self.chunks([words]), voice: "", rate: 1) {
            if case .started = e, stoppedAt == nil {
                #expect(b.playback.hasPendingAudio, "audio is playing when the stop comes")
                let t = ContinuousClock.now
                stoppedAt = t
                b.stop()
                if !b.playback.hasPendingAudio { silentAfter = .now - t }
            }
            if case .played(let ms) = e, stoppedAt != nil, finished == nil { playedMs = ms }
            if case .finished(let s) = e {
                finished = s
                finishedAfter = stoppedAt.map { .now - $0 }
            }
        }
        #expect(finished == true, "ended by the stop")
        let silent = try #require(silentAfter, "the output is silent once stop() returns")
        #expect(silent < .milliseconds(200), "stop → silence ≤ 200 ms (R-054 AC1)")
        let done = try #require(finishedAfter)
        #expect(done < .milliseconds(200), "stop → finished ≤ 200 ms (R-054 AC1)")
        // Cut short: what was heard is under the 30 s scheduled, and nothing is left to play.
        #expect(playedMs.map { $0 < 30_000 } == true, "played \(playedMs ?? -1) ms of 30000")
        #expect(b.playback.scheduledSamples == 0 && !b.playback.hasPendingAudio)
    }

    @Test func osGateTurnsKokoroOffOn26Point4And26Point5() {
        #expect(!KokoroBackend.osAllowsKokoro(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 1)))
        #expect(!KokoroBackend.osAllowsKokoro(OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)))
        #expect(KokoroBackend.osAllowsKokoro(OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 0)))
    }

    /// With the verified pack, read aloud runs on Kokoro (the leased `tts` object), speaking clause-first speakable chunks.
    @Test(.enabled(if: KokoroBackend.osAllowsKokoro()))
    func ttsServiceUsesKokoroWithThePack() async {
        let synth = FakeSynth()
        let provider = FakeTTSProvider(object: synth)
        let service = TTSService(basic: nil, provider: provider, kokoro: { KokoroBackend(tts: $0, output: .silent) })
        let models = VoiceModelSet(slots: [.tts: ModelSlot(engine: .coreml, key: "tts", path: "/m/tts")])
        let events = Mutex<[StreamItem]>([])
        await service.speak(Speak(text: "## Hi\n\nSure, here is the answer you wanted.\n\n```\nx\n```", voiceID: "", codeOmitted: "code omitted"),
                            models: models) { items in events.withLock { $0 += items } }
        let items = events.withLock { $0 }
        #expect(items.contains { if case .voice(.ttsStarted(0)) = $0 { true } else { false } })
        #expect(items.contains { if case .voice(.ttsStopped(_, .finished)) = $0 { true } else { false } })
        #expect(synth.texts.withLock { $0 } == ["Hi", "Sure, here is the answer you wanted.", "code omitted."])
        #expect(provider.released.withLock { $0 } == 1)
    }
}

final class FakeTTSProvider: VoiceModelProvider, @unchecked Sendable {
    let object: any Sendable
    let released = Mutex(0)
    init(object: any Sendable) { self.object = object }
    func lease(_ role: VoiceModelRole, _ slot: ModelSlot) async throws -> VoiceModelLease {
        VoiceModelLease(object: object) { self.released.withLock { $0 += 1 } }
    }
}

/// AT-NFR-V8 (make perf METRIC=V8): read aloud click → first audio with the real Kokoro (`tts`, warm), 20 runs each of a
/// 1-sentence and a 3-sentence reply, through TTSService (SpeakableText → ClauseChunker → KokoroBackend). Mode
/// [IN-PIPELINE]: the silent clock stands in for the speakers, so "first audio" = the first chunk's PCM handed to the
/// output (the player-node render adds the device's fixed output latency). Run under `gpu-run.sh timing`.
@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1" && ProcessInfo.processInfo.environment["ANTICHAT_V8"] == "1"))
struct ReadAloudLatencyTests {
    static let replies = [
        "one": "Sure, the meeting moved to Thursday at three in the afternoon.",
        "three": "Sure, the meeting moved to Thursday at three. **Bring** the slides from last week. I will send the room link soon.",
    ]

    @Test func v8ClickToFirstAudio() async throws {
        VoiceEnvironment.lockDown()
        let tts = try await KokoroTTS.load(slotDirectory: ParakeetBackendTests.models.appendingPathComponent("tts"))
        _ = try await tts.synthesize("Warm up.")
        let service = TTSService(basic: nil, provider: FakeTTSProvider(object: tts), kokoro: { KokoroBackend(tts: $0, output: .silent) })
        let models = VoiceModelSet(slots: [.tts: ModelSlot(engine: .coreml, key: "tts", path: "/m/tts")])
        var out: [String: [Double]] = [:]
        for (name, text) in Self.replies.sorted(by: { $0.key < $1.key }) {
            for _ in 0..<20 {
                let t0 = ContinuousClock.now
                let first = Mutex<Duration?>(nil)
                let req = Speak(text: text, voiceID: "")
                let task = Task {
                    await service.speak(req, models: models) { items in
                        if items.contains(where: { if case .voice(.ttsStarted) = $0 { true } else { false } }) {
                            first.withLock { if $0 == nil { $0 = ContinuousClock.now - t0 } }
                            Task { await service.stop(SpeakStop(requestID: req.requestID)) }
                        }
                    }
                }
                await task.value
                let d = try #require(first.withLock { $0 })
                out[name, default: []].append(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            }
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("build/at/AT-054")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["v8_s": out, "load": load[0], "mode": "[IN-PIPELINE] silent clock"],
                                   options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("v8.json"))
    }
}

@Suite struct FirstChunkCapTests {
    /// NFR-V1: a long first sentence without a clause mark is cut after 5 words; fed token by token the same.
    @Test func longFirstSentenceIsCutAfterFiveWords() {
        let text = "The quick brown fox jumps over the lazy dog near the river bank today. Next."
        let whole = ClauseChunker.chunks(text)
        #expect(whole.first == "The quick brown fox jumps")
        var c = ClauseChunker()
        var streamed: [String] = []
        for ch in text { streamed += c.feed(String(ch)) }
        streamed += c.finish()
        #expect(streamed == whole)
    }
}
