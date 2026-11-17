// M3.T12 AT-280 AC1 / AC3 (R-280): a live voice conversation on the Mac's own speakers and microphone, unattended.
//   AntiChat -Bench aec --script fixtures/audio/aec-10min/script.json [--minutes 10] [--model chat-9b-q4]
//                       [--duck 1|0] [--listen-seconds N] [--out build/at/AT-280/aec-events.json]
// The helper's VoiceSession runs live (VPIO full duplex on the default devices: `tools/voice/aec-10min.sh` selects
// the built-in microphone and speakers first); each reply is the helper's chat model, spoken through the VPIO output
// (the echo reference). The scripted user questions are played by `afplay` child processes, i.e. **outside** the
// echo reference, each started only after the previous reply finished + 1 s, so a question never overlaps the TTS.
// A self-interruption = a `ttsStopped(.bargeIn)` whose onset (`voice.bargeOnset`, shared uptime clock) is not within
// ±300 ms of a scripted question start. Pass (AC1): 0 self-interruptions and ≥ 18 of 20 questions answered.
// `--listen-seconds N` (AC3, `tools/voice/ducking-check.sh`): no questions, the session just listens for N seconds
// (the music bed plays meanwhile) with the ducking setting `--duck`.
// Developer-only: compiled in DEBUG and perf-harness builds, never in a release (tools/ci/dev-modes-guard.py).
#if DEBUG || ANTICHAT_PERF_HARNESS
@preconcurrency import AVFoundation
import AntiChatEngineProtocol
import AntiChatHarness
import Foundation

extension BenchMode {
    struct AECQuestion: Decodable {
        var wav: String
        var text: String?
    }

    static func aec(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let slot = DevModels.slot(a.opts["model"] ?? "chat-9b-q4")
        let models = conversationModels()
        guard models.slots.count == 5 else {
            throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "voice models missing: \(models.slots.keys)"])
        }
        let listenOnly = a.opts["listen-seconds"].flatMap(Double.init)
        var questions: [AECQuestion] = []
        var scriptDir = URL(fileURLWithPath: ".")
        if listenOnly == nil {
            let script = URL(fileURLWithPath: a.opts["script"] ?? "fixtures/audio/aec-10min/script.json").standardizedFileURL
            scriptDir = script.deletingLastPathComponent()
            struct Script: Decodable { var questions: [AECQuestion] }
            questions = try JSONDecoder().decode(Script.self, from: Data(contentsOf: script)).questions
        }
        for await _ in client.voiceStream(.models(models)) {}
        for await _ in client.warmupBatches(slot) {}
        let minutes = Double(a.opts["minutes"] ?? "10") ?? 10
        let now = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        let t0 = now()
        func ms(_ ns: UInt64) -> Double { Double(Int64(ns) - Int64(t0)) / 1e6 }
        let start = VoiceSessionStart(chatID: UUID(), locale: "en", voiceID: "af_heart", duckOthers: a.opts["duck"] != "0")
        let chatSession = UUID()
        var history: [ChatMessage] = [ChatMessage(role: .system, content: voiceSystemPrompt)]
        var questionStarts: [UInt64] = []
        var questionLog: [[String: Any]] = []
        var bargeIns: [[String: Any]] = []
        var lastBargeOnset: UInt64?
        var finals: [String] = []
        var replies = 0, repliesSpoken = 0
        var halfDuplex: String?
        var ducking: String?
        // Diagnostics: what the live session heard.
        var maxLevel: Float = -200, levelFrames = 0, loudFrames = 0, partials = 0
        var states: [String: Int] = [:]
        var errors: [String] = []
        var next = 0
        var player: Process?
        let session = client.voiceStream(.sessionStart(start))
        var replyTask: Task<String, Never>?
        var pendingQuestionAt: UInt64?
        let deadline = ContinuousClock.now + .seconds(minutes * 60 + (listenOnly ?? 0))
        let requestID = start.requestID
        let control: @Sendable (VoiceSessionControl.Action) -> Void = { action in
            _ = client.voiceSend(.sessionControl(VoiceSessionControl(requestID: requestID, action: action)))
        }
        // `--source afplay` (default): questions on this Mac's speakers (inside the VPIO echo reference on macOS, so
        // they are cancelled — A-M3-T12b); `remote`: a second device plays them (`tools/voice/aec-remote.py` serves a
        // page that polls `--remote-state`); `owner`: the owner speaks each prompted question live.
        let source = a.opts["source"] ?? "afplay"
        let remoteState = a.opts["remote-state"].map { URL(fileURLWithPath: $0) }
        func play(_ q: AECQuestion) {
            if source != "afplay" {
                let at = now()
                if source == "remote", let remoteState {
                    let wav = q.wav.hasPrefix("/") ? q.wav : scriptDir.appendingPathComponent(q.wav).standardizedFileURL.path
                    let doc: [String: Any] = ["seq": next + 1, "wav": wav, "text": q.text ?? ""]
                    if let d = try? JSONSerialization.data(withJSONObject: doc) { try? d.write(to: remoteState, options: .atomic) }
                }
                questionStarts.append(at)
                questionLog.append(["index": next, "wav": q.wav, "text": q.text ?? "", "start_ms": ms(at), "source": source])
                say(String(format: "%@ question %d/%d at %.1f s: %@", source == "owner" ? "SAY NOW →" : "remote",
                           next + 1, questions.count, ms(at) / 1000, (q.text ?? q.wav).capitalized))
                next += 1
                return
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            let wav = q.wav.hasPrefix("/") ? q.wav : scriptDir.appendingPathComponent(q.wav).standardizedFileURL.path
            // `--question-volume V`: afplay's own gain (1 = as recorded).
            p.arguments = (a.opts["question-volume"].map { ["-v", $0] } ?? []) + [wav]
            let at = now()
            do { try p.run() } catch { errors.append("afplay: \(error)") }
            player = p
            questionStarts.append(at)
            questionLog.append(["index": next, "wav": q.wav, "text": q.text ?? "", "start_ms": ms(at)])
            say(String(format: "question %d at %.1f s: %@", next + 1, ms(at) / 1000, q.text ?? q.wav))
            next += 1
        }
        // A pump ticks the loop so a question can start on time even when the helper is quiet.
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                tick.yield()
            }
        }
        enum Input { case batch(EngineBatch), tick, ended }
        let (inputs, input) = AsyncStream<Input>.makeStream()
        let sessionPump = Task {
            for await b in session { input.yield(.batch(b)) }
            input.yield(.ended)
        }
        let tickPump = Task { for await _ in ticks { input.yield(.tick) } }
        var listening = false
        var listenStart: UInt64?
        loop: for await item in inputs {
            switch item {
            case .ended: break loop
            case .tick: break
            case .batch(let batch):
                for it in batch.items {
                    switch it {
                    case .voice(.voiceState(.listening)) where !listening:
                        listening = true
                        listenStart = now()
                        say("aec: session listening")
                        pendingQuestionAt = now() + 2_000_000_000  // first question 2 s after the session listens
                    case .voice(.audioLevel(let l)):
                        levelFrames += 1
                        maxLevel = max(maxLevel, l)
                        if l > -40 { loudFrames += 1 }
                    case .voice(.partialTranscript):
                        partials += 1
                    case .voice(.voiceState(let st)) where st != .halfDuplex && st != .listening:
                        states["\(st)", default: 0] += 1
                    case .voice(.voiceState(.halfDuplex)):
                        halfDuplex = "switched at \(Int(ms(now()))) ms"
                    case .voice(.signpost("voice.bargeOnset", let ns)):
                        lastBargeOnset = ns
                    case .voice(.signpost(let n, _)) where n.hasPrefix("voice.halfDuplex."):
                        halfDuplex = n
                    case .voice(.signpost(let n, _)) where n.hasPrefix("audio.ducking."):
                        ducking = String(n.dropFirst("audio.ducking.".count))
                    case .voice(.finalTranscript(let f)) where replyTask == nil:
                        finals.append(f.text)
                        if !questionLog.isEmpty {
                            questionLog[questionLog.count - 1]["final"] = f.text
                            questionLog[questionLog.count - 1]["final_ms"] = ms(now())
                        }
                        history.append(ChatMessage(role: .user, content: f.text))
                        let req = ChatRequest(sessionID: chatSession, modelSlot: slot, messages: history.map { .message($0) },
                                              sampling: Sampling(temperature: 0.7, maxTokens: a.int("max-tokens", 120)))
                        let turn = UUID()
                        replies += 1
                        replyTask = Task {
                            var text = ""
                            do {
                                for try await e in client.chat(req) {
                                    if case .textDelta(let s) = e, !s.isEmpty {
                                        text += s
                                        control(.speak(text: s, turnID: turn))
                                    }
                                }
                            } catch {}
                            control(.speakEnd(turnID: turn))
                            return text
                        }
                    case .voice(.ttsStarted(chunkIndex: 0)):
                        repliesSpoken += 1
                        if !questionLog.isEmpty { questionLog[questionLog.count - 1]["spoken"] = true }
                    case .voice(.ttsStopped(_, let reason)):
                        let text = await replyTask?.value ?? ""
                        replyTask = nil
                        if !text.isEmpty { history.append(ChatMessage(role: .assistant, content: text)) }
                        if reason == .bargeIn {
                            let onset = lastBargeOnset ?? now()
                            let nearest = questionStarts.map { abs(Double(Int64(onset) - Int64($0)) / 1e6) }.min() ?? .infinity
                            let isSelf = source == "owner" ? true : nearest > 300  // owner mode: re-judged below
                            bargeIns.append(["onset_ms": ms(onset), "nearest_question_ms": nearest.isFinite ? nearest : -1, "self": isSelf])
                            say(String(format: "barge-in at %.1f s (%@)", ms(onset) / 1000, isSelf ? "SELF-INTERRUPTION" : "user"))
                        }
                        if !questionLog.isEmpty { questionLog[questionLog.count - 1]["reply_end"] = reason.rawValue }
                        // The next question 1 s after the reply ended (never over the TTS).
                        if listenOnly == nil { pendingQuestionAt = now() + 1_000_000_000 }
                    case .engine(.error(let e)):
                        errors.append(e.fullCode)
                        say("error: \(e.fullCode)")
                    default: break
                    }
                }
            }
            let t = now()
            if source == "remote", let remoteState, !questionStarts.isEmpty,
               let ack = try? String(contentsOf: remoteState.appendingPathExtension("started"), encoding: .utf8),
               Int(ack.trimmingCharacters(in: .whitespacesAndNewlines)) == questionStarts.count,
               questionLog.last?["acked"] == nil {
                questionStarts[questionStarts.count - 1] = t  // the device started playing (≤ 100 ms tick)
                questionLog[questionLog.count - 1]["acked"] = true
                questionLog[questionLog.count - 1]["start_ms"] = ms(t)
            }
            if let at = pendingQuestionAt, t >= at, listenOnly == nil, player?.isRunning != true {
                pendingQuestionAt = nil
                if next < questions.count { play(questions[next]) }
            }
            // A question that got no turn (nothing recognised) moves on after 15 s of silence from the session.
            if listenOnly == nil, replyTask == nil, pendingQuestionAt == nil, let last = questionStarts.last,
               questionLog.last?["final"] == nil, t > last + (source == "owner" ? 30 : 15) * 1_000_000_000,
               player?.isRunning != true {
                pendingQuestionAt = t
            }
            // Listen-only: N seconds from the moment the session listens (model loading comes first).
            let done = listenOnly.map { s in listenStart.map { Double(t - $0) / 1e9 > s } ?? false }
                ?? (next >= questions.count && replyTask == nil && pendingQuestionAt != nil)
            if done || ContinuousClock.now > deadline { break loop }
        }
        player?.terminate()
        _ = client.voiceSend(.sessionEnd(VoiceSessionEnd(requestID: start.requestID)))
        ticker.cancel()
        tickPump.cancel()
        sessionPump.cancel()
        if source == "owner" {
            // The owner talking over a reply is followed by their transcript; echo is not (nothing recognisable).
            for i in bargeIns.indices {
                let onset = bargeIns[i]["onset_ms"] as? Double ?? 0
                let answered = questionLog.contains { q in
                    guard q["final"] != nil, let s = q["start_ms"] as? Double else { return false }
                    return s <= onset + 1 && (q["final_ms"] as? Double ?? .infinity) - onset < 5_000
                }
                bargeIns[i]["self"] = !answered
            }
        }
        let selfInterruptions = bargeIns.filter { $0["self"] as? Bool == true }.count
        let answered = questionLog.filter { $0["final"] != nil && $0["spoken"] as? Bool == true }.count
        var o = base
        o["kind"] = listenOnly == nil ? "aec" : "listen"
        o["mode"] = "live"
        o["chat"] = slot.key
        o["duck_others"] = start.duckOthers
        o["ducking_applied"] = ducking ?? NSNull()
        o["diagnostics"] = ["max_level_dbfs": maxLevel, "level_frames": levelFrames, "frames_over_minus40": loudFrames,
                            "partials": partials, "states": states]
        o["minutes"] = ms(now()) / 60_000
        o["source"] = source
        o["questions"] = questionLog
        o["questions_played"] = questionLog.count
        o["answered"] = answered
        o["barge_ins"] = bargeIns
        o["self_interruptions"] = selfInterruptions
        o["half_duplex"] = halfDuplex ?? NSNull()
        o["replies"] = replies
        o["errors"] = errors
        o["pass"] = listenOnly == nil ? (selfInterruptions == 0 && answered >= 18 && halfDuplex == nil) : NSNull()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        o["loadavg"] = load
        raw.write(o)
        if let out = a.opts["out"] {
            let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: out).deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: out))
        }
        say("aec: \(questionLog.count) questions, \(answered) answered, \(selfInterruptions) self-interruptions, half duplex \(halfDuplex ?? "no")")
    }
}
#endif
