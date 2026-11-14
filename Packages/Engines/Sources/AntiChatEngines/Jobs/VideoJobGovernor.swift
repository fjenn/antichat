// M5.T11 (NFR-B3, NFR-B5, R-041): heat and other apps, for the one running video job. EngineRuntime owns one
// governor; the engines call `checkpoint` at every step boundary (VideoEngine on each denoise progress event,
// SDVideoEngine when a poll sees a new step, ScriptedVideoEngine after each scripted step).
//   * `.serious` (ThermalPolicy.videoAction → paceSteps 2 s): a 2 s sleep at every step boundary, card line
//     `thermal.serious`. FastMetal runtime (cooperative target): `/pause` blocks the sampler at its next `pause_check`
//     (UP-FV-001), so the pause is armed ahead — sent right after the previous resume (300 ms later, past the sampler's
//     wake-up) — and every boundary really waits 2 s; it is never re-armed after the last step (decode must run).
//     sd-server (signal target): SIGSTOP at the boundary the poll saw, SIGCONT 2 s later (never mid-command).
//   * `.critical` → hold `hot`: the job pauses (`/pause`, or SIGSTOP at the next boundary) with `video.paused.hot`
//     and [Resume]; it resumes when the state drops below critical or on [Resume] (the user's choice holds until
//     the state changes again). Chat keeps running: only the job's child is paused.
//   * Another app on the GPU (GPUYieldMonitor) → the child goes to Darwin background priority, and with the setting
//     on (default) hold `app`: paused with `video.paused.app` until the monitor sees the load gone.
// Every change reaches the card as one `SchedulerNote(action: "videoState")` (never a silent change).
// Cancel always wins: a paused job resumes (SIGCONT / `/resume`) before the cancel path runs.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation

/// The running job's child as the governor pauses it.
public protocol VideoPauseTarget: Sendable {
    /// The child's pid (background priority); 0 = none (scripted engine).
    var pid: Int32 { get }
    /// True: `pause()` is cooperative and takes effect at the child's next step boundary by itself (the FastMetal
    /// runtime's `/pause`), so it may be sent any time. False: it stops the process at once (SIGSTOP), so it is sent
    /// only at a step boundary.
    var cooperative: Bool { get }
    func pause() async
    func resume() async
}

/// sd-server: SIGSTOP / SIGCONT (ProcessPause).
public struct SignalPauseTarget: VideoPauseTarget {
    public let pid: Int32
    public var cooperative: Bool { false }
    public init(pid: Int32) { self.pid = pid }
    public func pause() async { ProcessPause.stop(pid) }
    public func resume() async { ProcessPause.resume(pid) }
}

/// The FastMetal / LTX runtime server: `POST …/pause` / `…/resume` of the running job (VideoEngine).
public struct RuntimePauseTarget: VideoPauseTarget {
    public let pid: Int32
    let engine: VideoEngine
    public var cooperative: Bool { true }
    public init(pid: Int32, engine: VideoEngine) {
        self.pid = pid
        self.engine = engine
    }
    public func pause() async { _ = await engine.pause() }
    public func resume() async { _ = await engine.resume() }
}

/// No child (scripted engine, tests): nothing to signal; the checkpoint still waits.
public struct NoChildPauseTarget: VideoPauseTarget {
    public init() {}
    public var pid: Int32 { 0 }
    public var cooperative: Bool { false }
    public func pause() async {}
    public func resume() async {}
}

public actor VideoJobGovernor {
    public typealias Emit = @Sendable (MediaEvent) async -> Void

    public enum Hold: String, Sendable { case hot, app }

    /// What the card shows (published as `SchedulerNote(action: "videoState")`).
    public struct Status: Sendable, Equatable {
        public var paused: Hold?
        public var notice: String?
        public var background: Bool
    }

    public static let noteAction = "videoState"

    public var stepPause: Duration
    public var poll: Duration
    /// Delay before re-arming a cooperative pause after a resume (the sampler thread must wake first).
    public var rearmDelay: Duration

    public private(set) var thermal: ThermalPolicy.State = .nominal
    private var otherAppBusy = false
    private var yieldEnabled = true
    /// Holds the user resumed through ([Resume]); cleared when the cause ends.
    private var overridden: Set<Hold> = []
    private var emit: Emit?
    private var target: (any VideoPauseTarget)?
    /// The target is paused by us right now (any cause).
    private var targetPaused = false
    /// The hold the target is paused for (nil = running or pacing).
    private var pausedFor: Hold?
    private var armed = false
    private var rearmTask: Task<Void, Never>?
    private var lastStatus: Status?
    private var background = false
    /// Calls made to the target, in order (tests).
    public private(set) var log: [String] = []

    public init(stepPause: Duration = .seconds(ThermalPolicy.videoSeriousStepPause), poll: Duration = .milliseconds(100),
                rearmDelay: Duration = .milliseconds(300)) {
        self.stepPause = stepPause
        self.poll = poll
        self.rearmDelay = rearmDelay
    }

    public func configure(stepPause: Duration? = nil, poll: Duration? = nil, rearmDelay: Duration? = nil) {
        if let stepPause { self.stepPause = stepPause }
        if let poll { self.poll = poll }
        if let rearmDelay { self.rearmDelay = rearmDelay }
    }

    // MARK: job lifecycle

    /// A video job starts (before its child exists). The thermal state carries over from the runtime.
    public func begin(emit: @escaping Emit, yieldEnabled: Bool) async {
        self.emit = emit
        self.yieldEnabled = yieldEnabled
        overridden = []
        otherAppBusy = false
        target = nil
        targetPaused = false
        pausedFor = nil
        armed = false
        background = false
        lastStatus = nil
        log = []
        await publish(force: thermal != .nominal)
    }

    /// The engine knows its child: background priority / a cooperative hold apply at once.
    public func attach(_ t: any VideoPauseTarget) async {
        target = t
        if otherAppBusy { setBackground(true) }
        await applyCooperative()
    }

    /// The job ended (any way): the child runs again at normal priority before anything else touches it.
    public func end() async {
        rearmTask?.cancel()
        rearmTask = nil
        if targetPaused || armed { await resumeTarget() }
        if background { setBackground(false) }
        target = nil
        emit = nil
        armed = false
        pausedFor = nil
    }

    public var isActive: Bool { emit != nil }
    /// The job is not using the GPU right now (paused for any cause): the monitor's fallback samples only then.
    public var isIdle: Bool { targetPaused && !armedOnly }
    private var armedOnly: Bool { armed && pausedFor == nil && !inStepPause }
    private var inStepPause = false
    public var status: Status { currentStatus() }
    public var childPID: Int32 { target?.pid ?? 0 }

    // MARK: inputs

    public func setThermal(_ s: ThermalPolicy.State) async {
        guard s != thermal else { return }
        thermal = s
        if s != .critical { overridden.remove(.hot) }
        if !isPacing { await disarm() }
        await applyCooperative()
        await publish()
    }

    /// GPUYieldMonitor's verdict: another app holds the GPU (true) or let go (false).
    public func setOtherAppBusy(_ busy: Bool) async {
        guard busy != otherAppBusy else { return }
        otherAppBusy = busy
        if !busy { overridden.remove(.app) }
        setBackground(busy)
        await applyCooperative()
        await publish()
    }

    /// [Resume] on the card: run through the current holds until their cause changes.
    public func userResume() async {
        overridden.formUnion(rawHolds)
        await applyCooperative()
        await publish()
    }

    /// The engine left the denoise loop (decode, frames): no pause may stay armed.
    public func leftDenoise() async {
        rearmTask?.cancel()
        rearmTask = nil
        await disarm()
    }

    // MARK: step boundary

    /// Called at a step boundary (`step` of `total`, after the step finished). Holds are waited out; at `.serious`
    /// the job sleeps `stepPause`. Returns when the job may continue or `isCancelled()` turned true.
    public func checkpoint(step: Int = 0, total: Int = 0, isCancelled: @escaping @Sendable () -> Bool) async {
        while let h = activeHold, !isCancelled() {
            if !targetPaused || pausedFor != h { await pauseTarget(for: h) }
            try? await Task.sleep(for: poll)
        }
        if isCancelled() { await releaseForCancel(); return }
        if pausedFor != nil { await resumeTarget() }
        guard isPacing else { return }
        inStepPause = true
        if !targetPaused { await pauseTarget(for: nil) }
        let until = ContinuousClock.now + stepPause
        while ContinuousClock.now < until, !isCancelled() {
            if activeHold != nil { break }
            try? await Task.sleep(for: min(poll, until - ContinuousClock.now))
        }
        inStepPause = false
        if isCancelled() { await releaseForCancel(); return }
        if activeHold != nil {
            await checkpoint(step: step, total: total, isCancelled: isCancelled)
            return
        }
        await resumeTarget()
        // Arm the next boundary ahead (cooperative target, more steps to come).
        if let t = target, t.cooperative, total > 0, step < total { scheduleRearm() }
    }

    // MARK: internals

    private var rawHolds: Set<Hold> {
        var h: Set<Hold> = []
        if case .pause = ThermalPolicy.videoAction(thermal) { h.insert(.hot) }
        if otherAppBusy && yieldEnabled { h.insert(.app) }
        return h
    }

    private var activeHold: Hold? {
        let h = rawHolds.subtracting(overridden)
        return h.contains(.hot) ? .hot : h.contains(.app) ? .app : nil
    }

    private var isPacing: Bool { if case .paceSteps = ThermalPolicy.videoAction(thermal) { true } else { false } }

    /// A cooperative target takes holds (and their release) at once; a signal target waits for the next checkpoint
    /// to pause, but is always released at once (SIGCONT is safe any time).
    private func applyCooperative() async {
        guard let t = target else { return }
        if let h = activeHold {
            if t.cooperative, pausedFor != h { await pauseTarget(for: h) }
        } else if pausedFor != nil {
            await resumeTarget()
            if isPacing, t.cooperative { scheduleRearm() }
        }
    }

    private func pauseTarget(for hold: Hold?) async {
        rearmTask?.cancel()
        rearmTask = nil
        if !targetPaused {
            log.append("pause")
            await target?.pause()
            targetPaused = true
        }
        if hold != nil { armed = false }
        pausedFor = hold
        await publish()
    }

    private func resumeTarget() async {
        let wasHeld = pausedFor != nil
        if targetPaused {
            log.append("resume")
            await target?.resume()
        }
        targetPaused = false
        armed = false
        pausedFor = nil
        if wasHeld { await publish() }
    }

    private func releaseForCancel() async {
        rearmTask?.cancel()
        rearmTask = nil
        inStepPause = false
        if targetPaused { await resumeTarget() }
    }

    private func disarm() async {
        if armed, pausedFor == nil, !inStepPause { await resumeTarget() }
        armed = false
    }

    private func scheduleRearm() {
        rearmTask?.cancel()
        let delay = rearmDelay
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.rearm()
        }
    }

    private func rearm() async {
        guard isPacing, let t = target, t.cooperative, !targetPaused, activeHold == nil else { return }
        log.append("pause")
        await t.pause()
        targetPaused = true
        armed = true
    }

    private func setBackground(_ on: Bool) {
        guard on != background else { return }
        background = on
        if let pid = target?.pid, pid > 0 { ProcessPause.setBackground(pid, on) }
        log.append(on ? "background" : "foreground")
    }

    private func currentStatus() -> Status {
        Status(paused: pausedFor, notice: pausedFor == nil ? (isPacing ? ThermalPolicy.videoNotice(thermal) : nil) : nil,
               background: background)
    }

    private func publish(force: Bool = false) async {
        let s = currentStatus()
        guard force || s != lastStatus, let emit else { return }
        lastStatus = s
        var d: [String: String] = ["paused": s.paused?.rawValue ?? "", "notice": s.notice ?? "", "background": s.background ? "1" : "0"]
        if let p = s.paused { d["copyKey"] = p == .hot ? "video.paused.hot" : "video.paused.app" }
        if s.paused == .hot { d["action"] = "resume" }
        await emit(.scheduler(SchedulerNote(action: Self.noteAction, model: "video", detail: d)))
    }
}
