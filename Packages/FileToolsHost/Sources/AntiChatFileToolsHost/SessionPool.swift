// The per-chat interpreter pool of the FileTools service (M6.T17; architecture §4 row 5; A-M6-03): one persistent
// REPL per chat (globals survive between `run_python` calls). A session ends on a kill (limit breach, crash), on
// `ResetSession`, or after 10 idle minutes; the next run then starts a fresh interpreter (`RunResult.freshSession`,
// the model is told). The service exits once it has had no session for the idle period.
// M6.T21 review (A-M6-T21a): runs are serialised across chats and only the running chat has a jail and an
// interpreter (#5: all chats share this service's container, so a second live jail would be readable by the first
// chat's code); a jail goes with its session (#6). Between runs the interpreter is frozen (SIGSTOP), so code that
// outlives its reply (a thread, or a forged reply line) cannot run unmeasured (#1, #3); any line that is not the
// run's reply ends the session (#2).
import AntiChatEngineProtocol
import Darwin
import Foundation

public final class SessionPool: @unchecked Sendable {
    final class Session: @unchecked Sendable {
        let chatID: String
        let process: ReplProcess
        let runtimeRoot: String
        let gate = NSLock()  // one run at a time per chat
        var lastUsed = Date()
        init(chatID: String, process: ReplProcess, runtimeRoot: String) {
            self.chatID = chatID; self.process = process; self.runtimeRoot = runtimeRoot
        }
    }

    public let jail: Jail
    public let network: Bool
    /// Real (non-container) home: the Runtimes roots the sandbox exception names are under it.
    let realHome: String
    private let lock = NSLock()
    /// Held for a whole run: one run, one live jail at a time in this service (review #5, #7).
    private let runLock = NSLock()
    private var activeChat: String?
    private var sessions: [String: Session] = [:]
    private var lastActivity = Date()

    /// Tests of the watchdog's process-tree handling only (Launcher.bootstrapForkable).
    let interpreterMayFork: Bool
    /// The run clock (awake time; tests inject a simulated sleep).
    let clock: RunClock

    public init(jail: Jail, network: Bool, realHome: String = SessionPool.realHomeDirectory(), interpreterMayFork: Bool = false,
                clock: RunClock = .system) {
        self.jail = jail; self.network = network; self.realHome = realHome; self.interpreterMayFork = interpreterMayFork
        self.clock = clock
    }

    public static func realHomeDirectory() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// The only runtime locations accepted (A-M6-11; FileTools.entitlements names the same paths).
    public var allowedRuntimeRoots: [String] {
        ["AntiChat", "AntiChat-Dev"].map { "\(realHome)/Library/Application Support/\($0)/Runtimes/" }
    }

    public var sessionCount: Int { lock.lock(); defer { lock.unlock() }; return sessions.count }
    public var idleFor: TimeInterval { lock.lock(); defer { lock.unlock() }; return sessions.isEmpty ? Date().timeIntervalSince(lastActivity) : 0 }

    // MARK: Run

    /// Runs `req` with `inputFDs[i]` = the content of `req.inputs[i]` (descriptors stay owned by the caller).
    /// Returns the result and the opened output descriptors (owned by the caller).
    public func run(_ req: RunCode, inputFDs: [Int32]) -> (RunResult, [Int32]) {
        touch()
        guard req.protocolVersion == FileToolsProtocol.version else {
            return (RunResult(serviceError: "protocol \(req.protocolVersion) ≠ \(FileToolsProtocol.version)"), [])
        }
        guard Jail.validChatID(req.chatID) else { return (RunResult(serviceError: "bad chat id"), []) }
        let layout: RuntimeLayout
        do { layout = try validatedRuntime(req.runtimePath) } catch { return (RunResult(serviceError: "\(error)"), []) }
        runLock.lock()
        defer { runLock.unlock() }
        if let previous = activeChat, previous != req.chatID { reset(previous) }
        jail.removeAll(except: req.chatID)
        activeChat = req.chatID
        // A jail deleted under a live session (by something other than this pool, e.g. an older service build in
        // another app process sharing the container) leaves the interpreter in a deleted cwd where `out/` can never
        // exist again: end it, so this run starts fresh in the new jail and the model is told (freshSession).
        if !FileManager.default.fileExists(atPath: jail.folder(req.chatID).path) { endSession(req.chatID) }
        do {
            try jail.prepare(req.chatID)
            for (i, input) in req.inputs.enumerated() where i < inputFDs.count {
                try jail.copyIn(req.chatID, name: input.name, from: inputFDs[i])
            }
        } catch {
            return (RunResult(serviceError: "jail: \(error)"), [])
        }

        let (session, fresh, startError) = acquire(req.chatID, layout: layout, memoryCap: req.memoryCapBytes)
        guard let session else { return (RunResult(freshSession: true, serviceError: startError ?? "interpreter did not start"), []) }
        session.gate.lock()
        defer { session.gate.unlock(); session.lastUsed = Date(); touch() }

        let started = clock.awake(), startedContinuous = clock.continuous()
        let id = UUID().uuidString
        let line = String(decoding: (try? JSONSerialization.data(withJSONObject: ["id": id, "code": req.code])) ?? Data(), as: UTF8.self)
        var result = RunResult(freshSession: fresh)
        let outcome = execute(session, line: line, id: id, req: req)
        // Awake time (RunClock): a Mac that slept mid-run does not count the sleep as run time.
        result.wallSeconds = (outcome.endedAt ?? clock.awake()) - started
        result.asleepSeconds = max(0, (clock.continuous() - startedContinuous) - (clock.awake() - started))
        result.peakFootprintBytes = outcome.peakFootprint
        result.cpuPercent = outcome.cpuPercent
        result.watchdogMaxGapMs = outcome.maxGap * 1000
        result.watchdogRealtime = outcome.realtime
        if let reason = outcome.killed {
            end(req.chatID, session)
            result.killedReason = reason
            return (result, [])
        }
        guard let reply = outcome.reply else {
            end(req.chatID, session)
            result.killedReason = .crash
            return (result, [])
        }
        result.stdout = reply["stdout"] as? String ?? ""
        result.stderr = reply["stderr"] as? String ?? ""
        if let e = reply["error"] as? [String: Any] {
            result.error = RunError(type: e["type"] as? String ?? "Error", message: e["message"] as? String ?? "",
                                    traceback: e["traceback"] as? String, errno: e["errno"] as? Int)
        }
        let names = (reply["files"] as? [String]) ?? []
        let opened = jail.openOutputs(req.chatID, names: names)
        result.outFiles = opened.map { RunResult.Output(name: $0.name, size: $0.size) }
        return (result, opened.map(\.fd))
    }

    struct Outcome {
        var reply: [String: Any]?
        var killed: KilledReason?
        var peakFootprint: Int64 = 0
        var cpuPercent: Double = 0
        /// When the code stopped (reply, exit or the watchdog's kill decision): the run's wall clock ends here, not
        /// after the kill and reap (which can take seconds on a loaded Mac).
        var endedAt: TimeInterval?
        var maxGap: TimeInterval = 0
        var realtime = false
    }

    /// Sends the cell and waits for its reply line under the run's `Watchdog` (10 ms tick, shorter near a limit: wall clock, memory,
    /// process count; M6.T18). After the reply, every other process of the run is killed: nothing the code started
    /// outlives its run (between runs no watchdog measures them).
    func execute(_ s: Session, line: String, id: String, req: RunCode) -> Outcome {
        s.process.thaw()
        guard s.process.send(line) else { return Outcome(killed: .crash) }
        // The watchdog must win the CPU against the code it guards (AT-NFR-SEC3 at load ~140 saw a 5.5 % memory
        // overshoot): this thread runs user-interactive for the run, the interpreter itself at nice 10.
        var oldQoS = qos_class_self(); var oldRel: Int32 = 0
        _ = pthread_get_qos_class_np(pthread_self(), &oldQoS, &oldRel)
        _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        defer { _ = pthread_set_qos_class_self_np(oldQoS, oldRel) }
        // ... and in the real-time band (load ~100 starved even user-interactive: 2.02 x cap, 2026-11-08).
        let realtime = RealtimeWatchdogThread.enter()
        defer { if realtime { RealtimeWatchdogThread.leave() } }
        let dog = Watchdog(root: s.process.pid, memoryCap: req.memoryCapBytes, deadline: clock.awake() + req.timeoutS,
                           clock: clock, signalGate: { body in _ = s.process.whileUnreaped(body) })
        var ended = clock.awake()
        func outcome(_ reply: [String: Any]?, _ killed: KilledReason?) -> Outcome {
            Outcome(reply: reply, killed: killed, peakFootprint: dog.peakFootprint, cpuPercent: dog.cpuPercent, endedAt: ended,
                    maxGap: dog.maxGap, realtime: realtime)
        }
        while true {
            // Gated near the memory cap: the code runs only during this slice, stopped while it is measured.
            let gating = dog.gated
            dog.resumeAll()  // no-op unless the previous pass stopped it
            let next = s.process.reader.next(within: gating ? Watchdog.gateSlice : dog.nextTick)
            if gating { dog.stopAll() }
            if let l = next {
                guard let j = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any], j["id"] as? String == id else {
                    // Only the REPL writes this stream, one reply per request: anything else is the code writing
                    // to the protocol descriptor (review #2) → the session ends.
                    ended = clock.awake()
                    dog.killAll()
                    s.process.killGroup()
                    return outcome(nil, .crash)
                }
                ended = clock.awake()
                dog.resumeAll()
                let late = dog.check()
                s.process.whileUnreaped { for p in Watchdog.members(of: s.process.pid) where p != s.process.pid { kill(p, SIGKILL) } }
                if let late {
                    dog.killAll(); s.process.killGroup()
                    return outcome(nil, late)
                }
                // Frozen until the next run: a thread the code left running, or the cell itself after a forged
                // reply (review #1, #3), gets no CPU while no watchdog measures it.
                s.process.freeze()
                return outcome(j, nil)
            }
            // The interpreter is gone (EOF, or a child it forked still holds the pipe): why, from its wait status.
            if s.process.reader.isEOF || s.process.hasExited {
                ended = clock.awake()
                dog.killAll()
                let status = s.process.reap(within: 2)
                return outcome(nil, status.map { Watchdog.reason(forWaitStatus: $0) } ?? .crash)
            }
            if let reason = dog.check() {
                ended = clock.awake()
                dog.killAll()
                s.process.killGroup()
                return outcome(nil, reason)
            }
        }
    }

    // MARK: Sessions

    func validatedRuntime(_ path: String) throws -> RuntimeLayout {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path + "/"
        guard allowedRuntimeRoots.contains(where: { real.hasPrefix($0) && real.count > $0.count }) else {
            throw LaunchError.badRuntime("runtime path outside the Runtimes roots")
        }
        return try RuntimeLayout.load(URL(fileURLWithPath: path))
    }

    func limits(memoryCap: Int64) -> String { ProcessLimits(memoryCap: memoryCap).launcherSpec }

    private func acquire(_ chatID: String, layout: RuntimeLayout, memoryCap: Int64) -> (Session?, Bool, String?) {
        lock.lock()
        if let s = sessions[chatID], s.runtimeRoot == layout.root.path, !s.process.hasExited {
            lock.unlock()
            return (s, false, nil)
        }
        let stale = sessions.removeValue(forKey: chatID)
        lock.unlock()
        stale?.process.killGroup()
        let spec = LaunchSpec(runtime: layout, jail: jail.folder(chatID), network: network, limits: limits(memoryCap: memoryCap),
                              mayFork: interpreterMayFork)
        do {
            let p = try Launcher.spawn(spec)
            let s = Session(chatID: chatID, process: p, runtimeRoot: layout.root.path)
            lock.lock(); sessions[chatID] = s; lock.unlock()
            return (s, true, nil)
        } catch {
            return (nil, true, "\(error)")
        }
    }

    private func end(_ chatID: String, _ s: Session) {
        s.process.killGroup()
        lock.lock()
        if sessions[chatID] === s { sessions.removeValue(forKey: chatID) }
        lock.unlock()
        // The interpreter state is gone and so is its jail (review #6: no copies of the user's files outlive the
        // session; inputs are copied in again on the next run).
        jail.remove(chatID)
    }

    /// Ends the chat's interpreter only (its jail is already gone).
    private func endSession(_ chatID: String) {
        lock.lock()
        let s = sessions.removeValue(forKey: chatID)
        lock.unlock()
        s?.process.killGroup()
    }

    /// Ends the chat's interpreter and deletes its jail.
    @discardableResult
    public func reset(_ chatID: String) -> Bool {
        lock.lock()
        let s = sessions.removeValue(forKey: chatID)
        lock.unlock()
        s?.process.killGroup()
        let existed = s != nil || FileManager.default.fileExists(atPath: jail.folder(chatID).path)
        jail.remove(chatID)
        jail.removeUnowned()  // a dead instance's leftovers (another app process that ended) are not "this scratch"
        touch()
        return existed
    }

    /// A-M6-T21a (a): the app moves this slot's lease to another chat. Waits for a run in progress, ends every
    /// interpreter and deletes every jail. Returns whether anything existed.
    @discardableResult
    public func wipe() -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for s in all { s.process.killGroup() }
        let existed = !all.isEmpty || !jail.isEmpty
        jail.removeAll()
        activeChat = nil
        touch()
        return existed
    }

    /// Ends sessions idle for `seconds` (A-M6-03: 10 min) and deletes their jails.
    public func reapIdle(olderThan seconds: TimeInterval = FileToolsProtocol.idleSeconds) {
        let now = Date()
        lock.lock()
        let idle = sessions.values.filter { now.timeIntervalSince($0.lastUsed) >= seconds && $0.gate.try() }
        for s in idle { sessions.removeValue(forKey: s.chatID); s.gate.unlock() }
        lock.unlock()
        for s in idle { s.process.killGroup(); jail.remove(s.chatID) }
        // No session and no run: no jail either (crash leftovers, a killed run's folder).
        if sessionCount == 0, runLock.try() {
            jail.removeAll(); activeChat = nil
            runLock.unlock()
        }
    }

    /// Kills every session (service shutdown).
    public func shutdown() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        for s in all { s.process.killGroup() }
    }

    private func touch() { lock.lock(); lastActivity = Date(); lock.unlock() }
}
