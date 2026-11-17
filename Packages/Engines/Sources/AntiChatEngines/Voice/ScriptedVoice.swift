// M3.T03 (environment §5; test-strategy §4.2): ScriptedVoice feeds fixture WAVs into the capture path in place of
// the microphone — `-UseScriptedVoice <script.jsonl>` in DEBUG / test builds only (the app passes the script to the
// helper with `DictationStart.scriptedInput`; Release ignores it). Every M3 AT runs on it (mode `inject`,
// `[IN-PIPELINE]`: no device or driver latency).
// Script: one JSON object per line, `{"t_ms": <start, ms from capture start>, "wav": <path>, "gain_db": <dB>}`
// (`gain_db` optional, 0). Items play at their start time (an item that would overlap the previous one starts when
// it ends); the gaps and the time after the last item are digital near-silence (−90 dBFS dither), as from a quiet
// microphone, until `stop`. Relative `wav` paths resolve against the fixtures root (the folder holding
// `voice/scripts/`), then the script's own folder. Audio is delivered in 20 ms frames at real-time pace
// (`speed` > 1 runs faster, for unit tests).
// Developer-only: compiled in DEBUG and perf-harness builds, never in a release (tools/ci/dev-modes-guard.py).
#if DEBUG || ANTICHAT_PERF_HARNESS
@preconcurrency import AVFoundation
import Foundation
import Synchronization

public final class ScriptedVoice: AudioCaptureSource, @unchecked Sendable {
    public struct Item: Codable, Sendable, Equatable {
        public var t_ms: Int
        public var wav: String
        public var gain_db: Double?
    }

    public let items: [Item]
    /// The mixed timeline (16 kHz mono) up to the end of the last item.
    public let timeline: [Float]
    public let speed: Double
    private let queue = DispatchQueue(label: "app.antichat.scripted-voice", qos: .userInteractive)
    private let state = Mutex<(timer: DispatchSourceTimer?, delivered: Int)>((nil, 0))

    public init(script: URL, speed: Double = 1) throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("//") }
        items = try lines.map { try JSONDecoder().decode(Item.self, from: Data($0.utf8)) }
        self.speed = speed
        let dir = script.deletingLastPathComponent()
        let root = dir.lastPathComponent == "scripts" && dir.deletingLastPathComponent().lastPathComponent == "voice"
            ? dir.deletingLastPathComponent().deletingLastPathComponent() : dir
        var out: [Float] = []
        for item in items {
            let url = try Self.resolve(item.wav, root: root, scriptDir: dir)
            let gain = Float(pow(10, (item.gain_db ?? 0) / 20))
            let samples = try VoiceAudioConverter.readFile(url).map { $0 * gain }
            let start = max(out.count, item.t_ms * 16)
            if start > out.count { out += Self.quiet(start - out.count, seed: out.count) }
            out += samples
        }
        timeline = out
    }

    static func resolve(_ path: String, root: URL, scriptDir: URL) throws -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        for base in [root, scriptDir] {
            let u = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        throw NSError(domain: "AntiChat.voice", code: 2, userInfo: [NSLocalizedDescriptionKey: "ScriptedVoice: \(path) not found under \(root.path)"])
    }

    /// −90 dBFS deterministic dither (a live microphone is never digital zero).
    static func quiet(_ n: Int, seed: Int) -> [Float] {
        var x = UInt32(truncatingIfNeeded: seed &* 2_654_435_761 | 1)
        return (0..<n).map { _ in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return (Float(x) / Float(UInt32.max) - 0.5) * 6.3e-5
        }
    }

    /// The samples of `range` of the endless signal (timeline, then quiet).
    func samples(_ range: Range<Int>) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(range.count)
        if range.lowerBound < timeline.count { out += timeline[range.lowerBound..<min(range.upperBound, timeline.count)] }
        if range.upperBound > timeline.count {
            let from = max(range.lowerBound, timeline.count)
            out += Self.quiet(range.upperBound - from, seed: from)
        }
        return out
    }

    public func start(_ onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let frame = VoiceAudioFormat.frameSamples
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let speed = speed
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 * speed
            let due = Int(elapsed * VoiceAudioFormat.sampleRate) / frame * frame
            let from = self.state.withLock { $0.delivered }
            guard due > from else { return }
            self.state.withLock { $0.delivered = due }
            var at = from
            while at < due {  // 20 ms frames, as a capture callback would
                onSamples(self.samples(at..<(at + frame)))
                at += frame
            }
        }
        state.withLock { $0 = (timer, 0) }
        timer.schedule(deadline: .now(), repeating: .milliseconds(max(1, Int(10 / speed))), leeway: .milliseconds(1))
        timer.resume()
    }

    public func stop() {
        state.withLock { s in
            s.timer?.cancel()
            s.timer = nil
        }
        queue.sync {}  // no frame after stop returns
    }

    /// Seconds of scripted audio (to the end of the last item).
    public var duration: Double { Double(timeline.count) / VoiceAudioFormat.sampleRate }
}
#endif
