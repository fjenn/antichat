// M3.T11 perf probe (AT-NFR-V1, -V1b, -V2 stages; AT-283 eos), mode `inject` `[IN-PIPELINE]`:
//   AntiChat -Bench voice-session [--input fixtures/audio/dictation] [--runs 20] [--model chat-9b-q4] [--raw out.jsonl]
// The real conversation path across the process boundary: the helper's VoiceSession (ScriptedVoice as the microphone,
// VPIO bypassed; Silero, smart-turn, Parakeet + EOU, Kokoro into a silent output clock) and, in this process, the chat
// reply streamed from the helper's chat engine and forwarded clause by clause (`speak` deltas, `speakEnd`) exactly as
// `VoiceTurnBridge` does; the turns of the run are one chat (one llama-server session), and each
// `provisionalTranscript` prefills the turn it would send, like `VoiceTurnBridge` → `TurnController.prewarm`
// (`--no-prewarm` turns that off for an A/B). Chat + STT + TTS resident (one discarded warm turn first). Per utterance:
//   V1 = tts.firstSample − voice.lastVoicedFrame (helper host times on the shared uptime clock, `VoiceEvent.signpost`);
//   V2 stages: endpointing = turnEnded − lastVoiced, STT final = finalTranscript − turnEnded, LLM TTFT = first reply
//   delta (this process) − finalTranscript, first clause = tts.firstClauseReady − first delta, TTS first chunk =
//   tts.firstChunkSynth − firstClauseReady, audio out = firstSample − firstChunkSynth.
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatHarness
import Foundation

extension BenchMode {
    /// The conversation's voice set (the app's dev voice fallback uses it too, AntiChatApp `voiceFallback`): each role
    /// by its catalog key (`VoiceModelRole.developerDirectory`) — `turn` is the Core ML `turn-coreml`, never the ONNX
    /// `installs/turn` (M9.T05: that mismatch left `-Bench voice-session` with "voice models missing").
    static func conversationModels() -> VoiceModelSet { DevModels.voiceSet([.stt, .sttEOU, .vad, .turn, .tts]) }

    static func voiceSession(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let fixtures = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 } ?? "fixtures"
        let dir = URL(fileURLWithPath: a.opts["input"] ?? "\(fixtures)/audio/dictation").standardizedFileURL
        let slot = DevModels.slot(a.opts["model"] ?? "chat-9b-q4")
        let models = conversationModels()
        // The T0 catalog voice set has no Parakeet EOU (the session endpoints on smart-turn alone); the rest is required.
        guard [VoiceModelRole.stt, .vad, .turn, .tts].allSatisfy({ models.slots[$0] != nil }) else {
            throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "voice models missing: \(models.slots.keys)"])
        }
        for await _ in client.voiceStream(.models(models)) {}
        for await _ in client.warmupBatches(slot) {}
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("q") && $0.hasSuffix(".wav") }.sorted()
        let runs = a.int("runs", 20)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-bench-voice-\(getpid())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        var b = base
        b["mode"] = "inject"
        b["mode_label"] = "[IN-PIPELINE]"
        b["chat"] = slot.key
        b["models"] = models.slots.keys.map(\.rawValue).sorted()
        let order = [names[0]] + Array(names.prefix(runs))
        // One call = one chat: every turn uses the chat's session (its llama-server slot keeps the prefix), and a
        // `provisionalTranscript` prefills the turn it would send, as `VoiceTurnBridge` → `TurnController.prewarm`.
        let chatSession = UUID()
        func request(_ text: String, maxTokens: Int, seed: Int) -> ChatRequest {
            ChatRequest(sessionID: chatSession, modelSlot: slot, messages: [
                ChatMessage(role: .system, content: voiceSystemPrompt), ChatMessage(role: .user, content: text),
            ], sampling: Sampling(temperature: 0.7, maxTokens: maxTokens, seed: UInt64(seed)))
        }
        for (i, name) in order.enumerated() {
            let wav = dir.appendingPathComponent(name)
            let script = tmp.appendingPathComponent("\(i).jsonl")
            try "{\"t_ms\": 300, \"wav\": \"\(wav.path)\"}\n".write(to: script, atomically: true, encoding: .utf8)
            let start = VoiceSessionStart(chatID: UUID(), locale: "en", voiceID: "af_heart", scriptedInput: script.path)
            var marks: [String: UInt64] = [:]
            var transcript = "", reply = "", error: String?
            var firstDeltaNs: UInt64?
            var prewarms = 0, adoptions = 0
            var lastProvisionalNs: UInt64?
            let specFirstText = LockedNs()
            let speculation = SpeculativeReply(engine: client)
            let maxTokens = a.int("max-tokens", 80)
            let turn = UUID()
            // Models before every session, as VoiceSessionController does (a restarted helper starts with none).
            for await _ in client.voiceStream(.models(models)) {}
            let session = client.voiceStream(.sessionStart(start))
            var replyTask: Task<(String, UInt64?), Never>?
            let deadline = ContinuousClock.now + .seconds(60)
            loop: for await batch in session {
                for item in batch.items {
                    switch item {
                    case .voice(.signpost(let n, let ns)): if marks[n] == nil { marks[n] = ns }
                    case .voice(.provisionalTranscript(let t)) where replyTask == nil && a.opts["no-prewarm"] == nil:
                        prewarms += 1
                        lastProvisionalNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        if a.opts["prefill-only"] != nil {
                            let warm = request(t, maxTokens: 1, seed: i)
                            Task { for await _ in client.chatBatches(warm) {} }
                        } else {
                            // A-M3-T09c: generate from the pause transcript; its first clause is synthesised ahead.
                            let requestID = start.requestID
                            let firstText = specFirstText
                            firstText.withLock { $0 = nil }
                            speculation.start(request(t, maxTokens: maxTokens, seed: i), onText: { text in
                                firstText.withLock { if $0 == nil { $0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) } }
                                _ = client.voiceSend(.sessionControl(VoiceSessionControl(requestID: requestID, action: .speculate(text: text))))
                            })
                        }
                    case .voice(.finalTranscript(let f)) where replyTask == nil:
                        transcript = f.text
                        let req = request(f.text, maxTokens: maxTokens, seed: i)
                        let adopted = speculation.take(matching: req)
                        if adopted != nil { adoptions += 1 }
                        replyTask = Task {
                            var text = "", first: UInt64?
                            func delta(_ s: String) {
                                guard !s.isEmpty else { return }
                                if first == nil { first = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
                                text += s
                                _ = client.voiceSend(.sessionControl(VoiceSessionControl(
                                    requestID: start.requestID, action: .speak(text: s, turnID: turn))))
                            }
                            if let adopted {
                                do {
                                    for try await item in adopted.items { if case .event(.textDelta(let s)) = item { delta(s) } }
                                } catch {}
                            } else {
                                do {
                                    for try await e in client.chat(req) { if case .textDelta(let s) = e { delta(s) } }
                                } catch {}
                            }
                            _ = client.voiceSend(.sessionControl(VoiceSessionControl(requestID: start.requestID, action: .speakEnd(turnID: turn))))
                            return (text, first)
                        }
                    case .voice(.ttsStopped):
                        _ = client.voiceSend(.sessionEnd(VoiceSessionEnd(requestID: start.requestID)))
                    case .engine(.error(let e)): error = "\(e)"
                    default: break
                    }
                }
                if ContinuousClock.now > deadline {
                    error = error ?? "timeout"
                    _ = client.voiceSend(.sessionEnd(VoiceSessionEnd(requestID: start.requestID)))
                    break loop
                }
            }
            if let r = await replyTask?.value { (reply, firstDeltaNs) = r }
            speculation.cancel()
            func ms(_ to: UInt64?, _ from: UInt64?) -> Double? {
                guard let to, let from else { return nil }
                return Double(Int64(to) - Int64(from)) / 1e6
            }
            let lv = marks["voice.lastVoicedFrame"], te = marks["voice.turnEnded"], fin = marks["voice.finalTranscript"]
            let clause = marks["tts.firstClauseReady"], synth = marks["tts.firstChunkSynth"], sample = marks["tts.firstSample"]
            var o = b
            o["kind"] = i == 0 ? "warm" : "run"
            o["run"] = i
            o["utterance"] = name
            o["transcript"] = transcript
            o["reply"] = reply
            o["prewarms"] = prewarms
            o["speculation_adopted"] = adoptions > 0
            // Where the speculative pipeline spends its time (from the last voiced frame): the last pause transcript's
            // arrival, the adopted speculation's first text.
            o["provisional_after_voiced_ms"] = ms(lastProvisionalNs, marks["voice.lastVoicedFrame"]) ?? -1
            o["spec_first_text_after_voiced_ms"] = ms(specFirstText.withLock { $0 }, marks["voice.lastVoicedFrame"]) ?? -1
            if let v = ms(sample, lv) { o["v1_ms"] = v }
            var stages: [String: Double] = [:]
            stages["endpointing"] = ms(te, lv)
            stages["stt_final"] = ms(fin, te)
            stages["llm_ttft"] = ms(firstDeltaNs, fin)
            stages["first_clause"] = ms(clause, firstDeltaNs)
            stages["tts_first_chunk"] = ms(synth, clause)
            stages["audio_out"] = ms(sample, synth)
            o["stages_ms"] = stages
            o["turn_to_final_ms"] = ms(fin, te) ?? -1
            o["last_voiced_to_final_ms"] = ms(fin, lv) ?? -1
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
            o["loadavg"] = load
            if let error { o["error"] = error }
            raw.write(o)
            say(String(format: "%@ %@: V1 %.0f ms (endpoint %.0f, stt %.0f, ttft %.0f, clause %.0f, synth %.0f, out %.0f) — %@ → %@",
                       i == 0 ? "warm" : "run \(i)", name, o["v1_ms"] as? Double ?? -1, stages["endpointing"] ?? -1,
                       stages["stt_final"] ?? -1, stages["llm_ttft"] ?? -1, stages["first_clause"] ?? -1,
                       stages["tts_first_chunk"] ?? -1, stages["audio_out"] ?? -1, transcript, error ?? String(reply.prefix(60))))
        }
    }
}

/// A host time a speculation callback sets (bench).
final class LockedNs: @unchecked Sendable {
    private let lock = NSLock()
    private var v: UInt64?
    func withLock<R>(_ body: (inout UInt64?) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&v) }
}
