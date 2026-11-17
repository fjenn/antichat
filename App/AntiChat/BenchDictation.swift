// M3.T03 perf probes (AT-NFR-V6, -V7, -V10; AT-050 AC2 helper leg), mode `inject` `[IN-PIPELINE]`:
//   AntiChat -Bench dictation [--input fixtures/audio/dictation] [--runs 20] [--tier-cap T1|T0] [--raw out.jsonl]
//   AntiChat -Bench dictation-warm [--runs 20] [--raw out.jsonl]
// `dictation`: the real helper's DictationService with ScriptedVoice as the microphone (each fixture utterance
// ≤ 30 s at real-time pace, 0.3 s after capture start), Parakeet `stt` (+ `stt-eou` for live English partials unless
// `--tier-cap T0`, which drops it: the 500 ms re-run path), Silero `vad-files`. Per run:
//   V6 = first `partialTranscript` arrival − speech onset; speech onset = the first `voiceState(listening)` arrival
//        (capture start) + 0.3 s + the fixture's first frame ≥ −40 dBFS (32 ms frames). Device/driver latency excluded.
//   V7 = `finalTranscript` arrival − the ■ stop send (stop sent 0.3 s after the utterance's end).
//   WER of the final against the fixture `.txt`.
// `dictation-warm` (V10): evict `stt`, send the mic-hover hint (`Warmup{pack: voice, predictive}`), then a plain warm-up
// of the `stt` slot that returns when the model is resident: hover → STT ready (Core ML built inside the load). The
// helper stays up between runs (a cold *model*, not a cold helper process).
// Developer-only: compiled in DEBUG and perf-harness builds, never in a release (tools/ci/dev-modes-guard.py).
#if DEBUG || ANTICHAT_PERF_HARNESS
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatHarness
import Foundation

extension BenchMode {
    static func dictationModels(eou: Bool) -> VoiceModelSet { DevModels.voiceSet([.stt, .vad] + (eou ? [.sttEOU] : [])) }

    /// Seconds from the start of `wav` to its first 32 ms frame at or above `dBFS`.
    static func speechOnset(_ wav: URL, dBFS: Double = -40) throws -> Double {
        let f = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = AVAudioFrameCount(f.length)
        guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n) else { return 0 }
        try f.read(into: b)
        let x = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
        let frame = Int(f.processingFormat.sampleRate * 0.032)
        var i = 0
        while i + frame <= x.count {
            var ms = 0.0
            for k in i..<(i + frame) { ms += Double(x[k]) * Double(x[k]) }
            if 10 * log10(max(ms / Double(frame), 1e-12)) >= dBFS { return Double(i) / f.processingFormat.sampleRate }
            i += frame
        }
        return 0
    }

    static func wordErrors(_ ref: String, _ hyp: String) -> (Int, Int) {
        func words(_ s: String) -> [String] {
            var out = ""
            for u in s.uppercased().unicodeScalars {
                out.unicodeScalars.append(CharacterSet.letters.contains(u) || CharacterSet.decimalDigits.contains(u) || u == "'" ? u : " ")
            }
            return out.split(separator: " ").map(String.init)
        }
        let r = words(ref), h = words(hyp)
        var prev = Array(0...h.count)
        for (i, a) in r.enumerated() {
            var cur = [i + 1] + [Int](repeating: 0, count: h.count)
            for (j, b) in h.enumerated() { cur[j + 1] = min(prev[j] + (a == b ? 0 : 1), prev[j + 1] + 1, cur[j] + 1) }
            prev = cur
        }
        return (prev[h.count], r.count)
    }

    static func dictation(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let fixtures = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 } ?? "fixtures"
        let dir = URL(fileURLWithPath: a.opts["input"] ?? "\(fixtures)/audio/dictation").standardizedFileURL
        let eou = (a.opts["tier-cap"] ?? "T1") != "T0"
        let models = dictationModels(eou: eou)
        guard models.slots[.stt] != nil else { throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "no stt in \(DevModels.modelsDir.path)"]) }
        for await _ in client.voiceStream(.models(models)) {}
        // The 27 short utterances, then the 30 s monologue (`--runs 28` covers all; NFR-V7 is for ≤ 30 s utterances).
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".wav") }
        let names = all.filter { $0.hasPrefix("q") }.sorted() + all.filter { $0.hasPrefix("monologue") }.sorted()
        let runs = a.int("runs", 20)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-bench-dictation-\(getpid())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var b = base
        b["mode"] = "inject"
        b["mode_label"] = "[IN-PIPELINE]"
        b["partials"] = eou ? "stt-eou" : "rerun-500ms"
        b["models"] = models.slots.keys.map(\.rawValue).sorted()
        // One discarded dictation: Core ML programs compiled, ANE resident (the hover warm-up's job in the app).
        let order = [names[0]] + Array(names.prefix(runs))
        for (i, name) in order.enumerated() {
            let wav = dir.appendingPathComponent(name)
            let ref = (try? String(contentsOf: wav.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)) ?? ""
            let script = tmp.appendingPathComponent("\(i).jsonl")
            try "{\"t_ms\": 300, \"wav\": \"\(wav.path)\"}\n".write(to: script, atomically: true, encoding: .utf8)
            let file = try AVAudioFile(forReading: wav)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            let onset = 0.3 + (try speechOnset(wav))
            let start = DictationStart(locale: "en-US", scriptedInput: script.path)
            let t = DictationTimes()
            let stopper = Task {
                // Stop 0.3 s after the utterance ends (measured from capture start, once it is known).
                while t.listen == nil { try? await Task.sleep(for: .milliseconds(5)) }
                try? await Task.sleep(until: t.listen! + .seconds(0.3 + seconds + 0.3), clock: .continuous)
                t.stop = .now
                _ = client.voiceSend(.dictationStop(DictationStop(requestID: start.requestID, mode: .review)))
            }
            var tPartial: ContinuousClock.Instant?, tFinal: ContinuousClock.Instant?
            var final: FinalTranscript?, error: String?, partials = 0
            for await batch in client.voiceStream(.dictationStart(start)) {
                for item in batch.items {
                    switch item {
                    case .voice(.voiceState(.listening)): if t.listen == nil { t.listen = batch.receivedAt }
                    case .voice(.partialTranscript):
                        partials += 1
                        if tPartial == nil { tPartial = batch.receivedAt }
                    case .voice(.finalTranscript(let f)):
                        final = f
                        tFinal = batch.receivedAt
                    case .engine(.error(let e)): error = "\(e)"
                    default: break
                    }
                }
            }
            stopper.cancel()
            let tListen = t.listen, tStop = t.stop
            var o = b
            o["kind"] = i == 0 ? "warm" : "run"
            o["run"] = i
            o["utterance"] = name
            o["utterance_s"] = seconds
            o["onset_s"] = onset
            o["partials"] = partials
            if let tListen, let tPartial { o["v6_s"] = secs(tPartial - tListen) - onset }
            if let tStop, let tFinal { o["v7_s"] = secs(tFinal - tStop) }
            if let f = final {
                o["transcript"] = f.text
                let (e, n) = wordErrors(ref, f.text)
                o["word_errors"] = e
                o["words"] = n
            }
            if let error { o["error"] = error }
            raw.write(o)
            say(String(format: "%@ %@ (%.1fs): V6 %.3f s, V7 %.3f s, %d partials — %@", i == 0 ? "warm" : "run \(i)", name, seconds,
                       o["v6_s"] as? Double ?? -1, o["v7_s"] as? Double ?? -1, partials, error ?? final?.text ?? "-"))
        }
    }

    static func dictationWarm(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let models = dictationModels(eou: false)
        guard let stt = models.slots[.stt] else { throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "no stt"]) }
        for await _ in client.voiceStream(.models(models)) {}
        for i in 0...a.int("runs", 20) {
            for await _ in client.evict(key: stt.key) {}
            let t0 = ContinuousClock.now
            await client.hint(Warmup(modelSlot: stt, pack: "voice", predictive: true))
            let err = await client.warmup(stt, onLifecycle: nil)
            let d = secs(ContinuousClock.now - t0)
            var o = base
            o["kind"] = i == 0 ? "warm" : "run"
            o["run"] = i
            o["v10_s"] = d
            if let err { o["error"] = "\(err)" }
            raw.write(o)
            say(String(format: "%@: hover → stt ready %.3f s %@", i == 0 ? "warm" : "run \(i)", d, err.map { "\($0)" } ?? ""))
        }
    }
}

/// Capture-start and stop instants shared with the stopper task.
final class DictationTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var _listen: ContinuousClock.Instant?
    private var _stop: ContinuousClock.Instant?
    var listen: ContinuousClock.Instant? {
        get { lock.withLock { _listen } }
        set { lock.withLock { _listen = newValue } }
    }
    var stop: ContinuousClock.Instant? {
        get { lock.withLock { _stop } }
        set { lock.withLock { _stop = newValue } }
    }
}
#endif
