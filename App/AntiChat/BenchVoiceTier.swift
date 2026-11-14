// M9.T05: NFR-V8 and NFR-V11 per tier through the real helper at that tier's cap (the in-process tests
// ReadAloudLatencyTests / FileTranscriberRealTests take no cap, so T0 and T3 used to repeat the T1 number):
//   AntiChat -Bench read-aloud --tier-cap T0|T1|T2-24|T3-48 [--model <chat>] [--runs 20] [--raw out.jsonl]
//   AntiChat -Bench transcribe-file --tier-cap T0|T1|T3-48 [--model <chat>] [--runs 3] [--input long-60min.wav] [--raw out.jsonl]
// The cap is real: `SetPolicy(budgetB: B)` of the tier (from BenchMode.run) and the tier's chat model resident before
// every measurement (the reply being read aloud / the chat the file is attached to was answered by it), so the voice
// model loads, leases and runs inside that tier's budget beside it, as on a Mac of that tier.
//   read-aloud: `Speak` (Kokoro `tts`, silent clock: DEBUG `silentOutput`, nothing plays) → the first `ttsStarted`
//               (first chunk's PCM handed to the output), then SpeakStop; 1- and 3-sentence replies alternate (the
//               ReadAloudLatencyTests texts). Mode [IN-PIPELINE]. Run 0 per text is discarded (Kokoro's ANE warm-up).
//   transcribe-file: `TranscribeFile` (Parakeet `stt` + Silero `vad-files`, disk-backed, R-056) of the 60-min fixture
//               → its `done`; realtime_x = audio seconds ÷ wall seconds; n = 3 for a 60-min file (A-M3-03).
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatHarness
import Foundation

extension BenchMode {
    static let readAloudTexts: [(String, String)] = [
        ("one", "Sure, the meeting moved to Thursday at three in the afternoon."),
        ("three", "Sure, the meeting moved to Thursday at three. **Bring** the slides from last week. I will send the room link soon."),
    ]

    /// The tier's default chat model (the one resident beside the voice models), from `--model` or the cap's family.
    static func tierChat(_ a: Args) -> ModelSlot {
        let family = String((a.opts["tier-cap"] ?? "T1").prefix(2))
        return DevModels.slot(a.opts["model"] ?? ["T0": "chat-2b", "T3": "chat-35b-q4", "T4": "chat-35b-q4"][family] ?? "chat-9b-q4")
    }

    /// Loads the tier's chat model and fails the bench when it does not load (a silent miss would measure no tier).
    static func residentChat(_ a: Args, client: EngineClient) async throws -> (ModelSlot, Double) {
        let chat = tierChat(a)
        let t0 = ContinuousClock.now
        if let err = await client.warmup(chat, onLifecycle: nil) {
            throw NSError(domain: "bench", code: 8, userInfo: [NSLocalizedDescriptionKey: "chat model \(chat.key) did not load at the cap: \(err)"])
        }
        return (chat, secs(ContinuousClock.now - t0))
    }

    static func voiceModels(_ roles: [VoiceModelRole]) -> VoiceModelSet { DevModels.voiceSet(roles) }

    static func readAloud(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let models = voiceModels([.stt, .vad, .tts])
        guard models.slots[.tts] != nil else { throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "no tts in \(DevModels.modelsDir.path)"]) }
        for await _ in client.voiceStream(.models(models)) {}
        let (chat, chatLoad) = try await residentChat(a, client: client)
        let runs = a.int("runs", 20)
        var b = base
        b["mode_label"] = "[IN-PIPELINE] silent clock"
        b["chat"] = chat.key
        b["chat_load_s"] = chatLoad
        say("read-aloud: cap \(a.opts["tier-cap"] ?? "?") chat \(chat.key) runs \(runs) per text (+1 warm)")
        for (name, text) in readAloudTexts {
            for i in 0...runs {
                for await _ in client.warmupBatches(chat) {}  // the reply's model stays resident (no-op once loaded)
                let req = Speak(text: text, voiceID: "", silentOutput: true)
                let t0 = ContinuousClock.now
                var first: Double?, error: String?, loads: [String] = []
                for await batch in client.voiceStream(.speak(req)) {
                    for item in batch.items {
                        switch item {
                        case .voice(.ttsStarted):
                            if first == nil {
                                first = secs(batch.receivedAt - t0)
                                _ = client.voiceSend(.speakStop(SpeakStop(requestID: req.requestID)))
                            }
                        case .lifecycle(.loadState(let s)): loads.append(s.rawValue)
                        case .engine(.error(let e)): error = "\(e)"
                        default: break
                        }
                    }
                }
                var o = b
                o["kind"] = i == 0 ? "warm" : "run"
                o["run"] = i
                o["text"] = name
                o["v8_s"] = first ?? -1
                o["load_states"] = loads.joined(separator: ",")
                if let error { o["error"] = error }
                raw.write(o)
                say(String(format: "%@ %@: click → first audio %.3f s %@", name, i == 0 ? "warm" : "run \(i)", first ?? -1, error ?? ""))
            }
        }
    }

    static func transcribeFile(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let fixtures = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 } ?? "fixtures"
        let url = URL(fileURLWithPath: a.opts["input"] ?? "\(fixtures)/audio/long-file/long-60min.wav").standardizedFileURL
        let file = try AVAudioFile(forReading: url)
        let audio = Double(file.length) / file.fileFormat.sampleRate
        let models = voiceModels([.stt, .vad])
        guard models.slots[.stt] != nil else { throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "no stt in \(DevModels.modelsDir.path)"]) }
        for await _ in client.voiceStream(.models(models)) {}
        let (chat, chatLoad) = try await residentChat(a, client: client)
        var b = base
        b["chat"] = chat.key
        b["chat_load_s"] = chatLoad
        b["file"] = url.lastPathComponent
        b["audio_s"] = audio
        let runs = a.int("runs", 3)
        say("transcribe-file: cap \(a.opts["tier-cap"] ?? "?") chat \(chat.key) \(url.lastPathComponent) (\(Int(audio)) s) runs \(runs)")
        for i in 0..<runs {
            for await _ in client.warmupBatches(chat) {}
            let req = TranscribeFile(fileURL: url, locale: a.opts["locale"] ?? "en")
            let t0 = ContinuousClock.now
            var final: FinalTranscript?, error: String?, progress = 0
            for await batch in client.voiceStream(.transcribeFile(req)) {
                for item in batch.items {
                    switch item {
                    case .voice(.transcribeProgress): progress += 1
                    case .voice(.finalTranscript(let f)): final = f
                    case .engine(.error(let e)): error = "\(e)"
                    default: break
                    }
                }
            }
            let wall = secs(ContinuousClock.now - t0)
            var o = b
            o["kind"] = "run"
            o["run"] = i
            o["seconds"] = wall
            o["realtime_x"] = final != nil && error == nil ? audio / wall : -1
            o["progress_events"] = progress
            o["chars"] = final?.text.count ?? 0
            o["load"] = ProcessInfo.processInfo.loadAverage1m
            if let error { o["error"] = error }
            raw.write(o)
            say(String(format: "run %d: %.1f s for %.0f s audio (%.1f×) %@", i, wall, audio, audio / wall, error ?? ""))
        }
    }
}
