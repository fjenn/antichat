// UI-alive probe for the engine-crash restart (M0.T04 step 10 fallback, Q-015): the XCUITest cannot run
// because enabling automation mode needs an interactive authorisation. Launched as
// `AntiChat -SpikeUI YES -SpikeProbe <out.json>`: it sends a prompt through the real SpikeChatModel, SIGKILLs
// the helper while text streams, then for 5 s pings the main queue every 100 ms (latency = enqueue → run)
// while "typing" into the composer model. It records whether the transcript shows the `engine.restarted`
// notice and whether Retry streams again. It measures the main run loop, not synthesised keystrokes
// [INFERENCE: a typed key is delivered by the same main run loop, so a stall would show in these pings].
import AntiChatUI
import Darwin
import Foundation

@MainActor
enum SpikeProbe {
    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    static func ping() async -> Double {
        let sent = ContinuousClock.now
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
        return secs(ContinuousClock.now - sent)
    }

    static func run(_ model: SpikeChatModel, out: String) async {
        var result: [String: Any] = [:]
        for _ in 0..<300 where model.lastAckPID == 0 { try? await Task.sleep(for: .milliseconds(100)) }
        let helper = model.lastAckPID
        result["helper_pid"] = helper
        // Let the helper live > 10 s first (launchd's respawn throttle, S-3 report).
        try? await Task.sleep(for: .seconds(11))
        model.input = "Write 300 words about tides."
        model.send()
        for _ in 0..<300 {
            if let t = model.turns.last?.text, t.count > 40 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        result["chars_before_kill"] = model.turns.last?.text.count ?? 0
        let t0 = ContinuousClock.now
        // pid 0 (never connected) would make kill() signal this app's whole process group.
        if helper > 0 { kill(pid_t(helper), SIGKILL) }  // same as `pkill -9 -f AntiChatEngine`
        var lat: [Double] = []
        var typed = ""
        for ch in "still here" {
            lat.append(await ping())
            typed.append(ch)
            model.input = typed
            try? await Task.sleep(for: .milliseconds(100))
        }
        while secs(ContinuousClock.now - t0) < 5 {
            lat.append(await ping())
            if model.showRestarted, result["restarted_notice_s"] == nil { result["restarted_notice_s"] = secs(ContinuousClock.now - t0) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        result["input_after_kill"] = model.input
        result["restarted_notice_shown"] = model.showRestarted
        result["worst_main_latency_s"] = lat.max() ?? -1
        result["pings"] = lat.count
        result["new_helper_pid"] = model.lastAckPID
        let before = model.turns.count
        model.retry()
        var streamedAfter: Double = -1
        for _ in 0..<200 {
            if model.turns.count > before, let t = model.turns.last?.text, !t.isEmpty {
                streamedAfter = secs(ContinuousClock.now - t0)
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        result["retry_streaming_after_kill_s"] = streamedAfter
        if let d = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: out))
        }
        model.stop()
        try? await Task.sleep(for: .milliseconds(300))
        exit(0)
    }
}
