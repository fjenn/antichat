// M3 review P1-5: a spoken tool approval through the real pipeline, mode `inject` `[IN-PIPELINE]`:
//   AntiChat -Bench voice-approval [--duplex full|half] [--answer-ms 9000] [--question fixtures/audio/dictation/q01.wav]
//                                  [--raw out.jsonl]
// The app's own `VoiceSessionController` + `VoiceTurnBridge` (exactly the classes a window uses) against the helper's
// VoiceSession with real models (Silero, smart-turn, Parakeet + EOU, Kokoro into the silent output clock; ScriptedVoice
// as the microphone: the question, then the spoken answer "Allow once." — synthesised with the system `say` to a
// 16 kHz WAV, never played aloud). The chat side is a scripted port: the question's turn answers "Sure, saving it."
// and raises an ApprovalCard for `write_note` (the bridge speaks "Write note. Allow?"); a spoken answer continues the
// reply ("Done, it is saved.") and ends it. `--duplex half` runs the session on a route without echo cancellation
// (the mic is gated while the assistant speaks). Pass = the card is answered `allowOnce` by voice, the reply that
// waited for the answer was never stopped, the answer was not sent as a chat message, and the session is listening
// again at the end.
// Developer-only: compiled in DEBUG and perf-harness builds, never in a release (tools/ci/dev-modes-guard.py).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import Foundation

@MainActor
final class ApprovalBenchPort: VoiceChatPort {
    weak var bridge: VoiceTurnBridge?
    var sent: [String] = []
    var stops: [(String, Int?)] = []
    var answers: [ApprovalAnswer] = []
    let assistantID = "bench-reply"

    func sendUserText(_ text: String) -> Bool {
        sent.append(text)
        guard sent.count == 1, let bridge else { return true }  // only the question starts the scripted reply
        bridge.replyStarted(assistantID)
        bridge.replyDelta(assistantID, "Sure, saving it.")
        bridge.approvalChanged(assistantID, ToolApprovalRequest(id: "call_1", tool: "write_note", argumentsJSON: "{}",
                                                                sideEffect: .write, untrusted: false))
        return true
    }

    func stopReply(_ assistantID: String, keepingUTF16: Int?) { stops.append((assistantID, keepingUTF16)) }

    func answerApproval(_ assistantID: String, callID: String, _ answer: ApprovalAnswer) {
        answers.append(answer)
        guard let bridge else { return }
        bridge.approvalChanged(assistantID, nil)
        bridge.replyDelta(assistantID, " Done, it is saved.")
        bridge.replyFinished(assistantID)
    }
}

extension BenchMode {
    @MainActor static func voiceApproval(_ a: Args, client: EngineClient, raw: RawWriter, base: [String: Any]) async throws {
        let models = conversationModels()
        guard models.slots.count == 5 else {
            throw NSError(domain: "bench", code: 7, userInfo: [NSLocalizedDescriptionKey: "voice models missing: \(models.slots.keys)"])
        }
        let fixtures = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"].flatMap { $0.isEmpty ? nil : $0 } ?? "fixtures"
        let question = URL(fileURLWithPath: a.opts["question"] ?? "\(fixtures)/audio/dictation/q01.wav").standardizedFileURL
        let half = a.opts["duplex"] == "half"
        let answerMs = a.int("answer-ms", 9_000)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-bench-approval-\(getpid())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // The spoken answer: pre-recorded with the system voice into a file (nothing plays aloud).
        let answer = tmp.appendingPathComponent("allow-once.wav")
        let tts = Process()
        tts.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        tts.arguments = ["-o", answer.path, "--data-format=LEI16@16000", "--file-format=WAVE", "Allow once."]
        try tts.run()
        tts.waitUntilExit()
        guard tts.terminationStatus == 0 else { throw NSError(domain: "bench", code: 8, userInfo: [NSLocalizedDescriptionKey: "say failed"]) }
        let script = tmp.appendingPathComponent("approval.jsonl")
        try ("{\"t_ms\": 300, \"wav\": \"\(question.path)\"}\n{\"t_ms\": \(answerMs), \"wav\": \"\(answer.path)\"}\n")
            .write(to: script, atomically: true, encoding: .utf8)

        let controller = VoiceSessionController(engine: client, models: { models }, scriptedInput: script.path,
                                                fakeAudio: half ? "route=noaec" : nil)
        let port = ApprovalBenchPort()
        port.bridge = controller.bridge
        controller.bridge.approvalPrompt = { "\($0). Allow?" }
        controller.start(port: port, chatID: nil, voiceID: "af_heart", rate: 1, mode: .handsFree, locale: "en",
                         codeOmitted: nil, duckOthers: false)
        let deadline = ContinuousClock.now + .seconds(a.int("timeout-s", 90))
        var sawListeningAfterAnswer = false
        while ContinuousClock.now < deadline {
            if case .error = controller.phase { break }
            if !port.answers.isEmpty, controller.bridge.current == nil, controller.phase == .listening {
                sawListeningAfterAnswer = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        var o = base
        o["kind"] = "run"
        o["mode"] = "inject"
        o["mode_label"] = "[IN-PIPELINE]"
        o["duplex"] = half ? "half" : "full"
        o["half_duplex_reported"] = controller.halfDuplex
        o["answer_ms"] = answerMs
        o["user_messages"] = port.sent
        o["answers"] = port.answers.map { "\($0)" }
        o["stops"] = port.stops.count
        o["barge_ins"] = controller.bargeIns
        o["listening_after_answer"] = sawListeningAfterAnswer
        o["phase"] = "\(controller.phase)"
        if let e = controller.lastError { o["error"] = e }
        let pass = port.answers == [.allowOnce] && port.stops.isEmpty && port.sent.count == 1 && sawListeningAfterAnswer
            && controller.halfDuplex == half
        o["pass"] = pass
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        o["loadavg"] = load
        controller.end()
        raw.write(o)
        say(String(format: "voice-approval (%@ duplex): %@ — answers %@, stops %d, barge-ins %d, user messages %@",
                   half ? "half" : "full", pass ? "PASS" : "FAIL", "\(port.answers)", port.stops.count, controller.bargeIns,
                   "\(port.sent)"))
        if !pass { throw NSError(domain: "bench", code: 9, userInfo: [NSLocalizedDescriptionKey: "voice-approval failed"]) }
    }
}
#endif
