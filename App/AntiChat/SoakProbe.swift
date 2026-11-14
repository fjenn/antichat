// M9.T06 (AT-NFR-S3; the spec's `SoakDriver`): the 8-hour mixed session, driven in-process like the other probes
// (XCUITest is blocked, Q-015, and the screen belongs to the concurrent capture runs: the app runs as a background
// run, never key, never front; nothing posts global input). `tools/perf/soak.sh` writes `<dir>/config.json`, launches
// the optimized perf-harness app (`make build-perf`) in a throwaway dev container with
// `-SoakProbe <dir> -FakeHardware T1 -ChatModel chat-9b-q4 -EvilChatModel llama:evil-9b -FakeVoiceInstalled YES
//  -UseScriptedVoice <dir>/voice.jsonl` and REAL models. One loop (the "phase" is the step name):
//   sample      a `loop` sample after 10 s idle — the same phase of every loop, which the growth verdict compares
//   image       when due (3 per hour by default): one picture through a MediaJobQueue → the helper → sd-server (real
//               img-klein q4 @ 768, or `image_mode: scripted` = ScriptedImageEngine buffers of `image_gb`, the T05
//               mini-soak's workload), ChildSafetyCheck gate on the output; the chat model steps aside on T0–T2
//   chat        a new Normal chat, 3 turns (the window's composer → TurnController → the real chat model)
//   voice       a voice conversation in a new chat: ScriptedVoice question → the helper's real VAD / smart-turn /
//               Parakeet STT → a chat turn → Kokoro TTS into the silent clock → listening again → End
//   evil        a new Evil chat, 1 turn (llama-server evil-9b: the Normal → Evil model swap)
//   normal      1 more turn in the loop's Normal chat (Evil → Normal swap back)
//   quickpanel  one question in the quick panel (shown concealed), the reply streamed, hidden
//   project     a new chat in the soak project (qa-50 docs linked once at setup: ProjectFileIndexer + embed), one
//               question answered through ProjectContextPlanner → ProjectRetriever
//   import      a small ChatGPT / Claude export (alternating) through ImportCoordinator
// Every `sample_s` (300) a `periodic` sample at whatever phase is running. A sample = phys_footprint of the app, the
// helper (HelperProbe) and the helper's children (llama-server, sd-server), Metal allocated (helper
// `MTLDevice.currentAllocatedSize` + the app's own), `vm_statistics64` swapouts / pageouts, the hang watchdog's
// counts. A watchdog thread pings the main queue every 250 ms; a main-thread stall ≥ 250 ms is a `mainThreadHang`
// signpost interval (subsystem app.antichat, category soak) and a `hangs.jsonl` row (> 2 s fails the soak); a stall
// ≥ 1 s also gets the main thread's sampled stacks in `hang-stacks/` (HangStackSampler: where the time went). MetricKit
// diagnostic payloads (hang + crash diagnostics) are kept in `<dir>/metrickit/`. Each reply that finished `done` is a
// saved message (`saved.jsonl`: chat, message, text sha256) — after a crash soak.sh checks none was lost.
// Outputs: samples.jsonl, events.jsonl, hangs.jsonl, hang-stacks/, saved.jsonl, status.json, result.json; quits at the end.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatPlatform
import AntiChatStorage
import AntiChatUI
import AppKit
import CryptoKit
import Darwin
import Foundation
import Metal
import MetricKit
import os

@MainActor
enum SoakProbe {
    struct Config: Decodable {
        var minutes: Double = 480
        var sample_s: Double = 300
        var images_per_hour: Double = 3
        var image_mode: String = "real"
        var image_gb: Double = 6.3
        var image_quant: String = "q4"
        var image_res: Int = 768
        var fixtures: String = "fixtures"
        var tier: String = "T1"
        var reply_timeout_s: Double = 600
        /// Legs to skip (smoke runs only; the AT run uses every leg and records the list).
        var skip: [String] = []

        enum CodingKeys: String, CodingKey {
            case minutes, sample_s, images_per_hour, image_mode, image_gb, image_quant, image_res, fixtures, tier
            case reply_timeout_s, skip
        }

        init() {}

        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            minutes = try c.decodeIfPresent(Double.self, forKey: .minutes) ?? minutes
            sample_s = try c.decodeIfPresent(Double.self, forKey: .sample_s) ?? sample_s
            images_per_hour = try c.decodeIfPresent(Double.self, forKey: .images_per_hour) ?? images_per_hour
            image_mode = try c.decodeIfPresent(String.self, forKey: .image_mode) ?? image_mode
            image_gb = try c.decodeIfPresent(Double.self, forKey: .image_gb) ?? image_gb
            image_quant = try c.decodeIfPresent(String.self, forKey: .image_quant) ?? image_quant
            image_res = try c.decodeIfPresent(Int.self, forKey: .image_res) ?? image_res
            fixtures = try c.decodeIfPresent(String.self, forKey: .fixtures) ?? fixtures
            tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? tier
            reply_timeout_s = try c.decodeIfPresent(Double.self, forKey: .reply_timeout_s) ?? reply_timeout_s
            skip = try c.decodeIfPresent([String].self, forKey: .skip) ?? skip
        }
    }

    private static var started = false
    static var dir = URL(fileURLWithPath: "/tmp")
    static var config = Config()
    static var t0 = ContinuousClock.now
    /// The app's engine (ChatEnvironment): the samples' HelperProbe.
    static var engine: (any EngineService)?
    static var loop = 0
    static var phase = "setup" {
        didSet { watchdog.setPhase(phase) }  // the hang rows' phase
    }
    static var counts: [String: Int] = [:]
    static var failures: [String: Int] = [:]
    static var errors: [String] = []
    static var helperRestarts = 0
    static var samplesWriter: BenchMode.RawWriter?
    static var eventsWriter: BenchMode.RawWriter?
    static var savedWriter: BenchMode.RawWriter?
    static let watchdog = HangWatchdog()
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "soak")

    static func log(_ s: String) { FileHandle.standardError.write(Data("SoakProbe: \(s)\n".utf8)) }
    static func elapsed() -> Double { PaletteProbe.seconds(ContinuousClock.now - t0) }

    static func start(_ state: WindowState, sessions: ChatSessions, out: String) {
        guard !started else { return }
        started = true
        t0 = ContinuousClock.now
        engine = sessions.environment.engine
        dir = URL(fileURLWithPath: out, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: dir.appendingPathComponent("config.json")) {
            do { config = try JSONDecoder().decode(Config.self, from: d) } catch { log("config.json: \(error)") }
        }
        samplesWriter = BenchMode.RawWriter(dir.appendingPathComponent("samples.jsonl").path)
        eventsWriter = BenchMode.RawWriter(dir.appendingPathComponent("events.jsonl").path)
        savedWriter = BenchMode.RawWriter(dir.appendingPathComponent("saved.jsonl").path)
        watchdog.start(dir: dir.appendingPathComponent("hangs.jsonl"))
        SoakMetricKit.shared.start(dir: dir.appendingPathComponent("metrickit", isDirectory: true))
        log("start \(config.minutes) min, tier \(config.tier), images \(config.image_mode) → \(out)")
        Task { @MainActor in
            await run(state, sessions)
            watchdog.stop()
            NSApp.terminate(nil)
            // A quit something holds (a running job's guard) must not keep the soak alive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { log("quit held; exiting"); exit(0) }
        }
    }

    // MARK: Run

    static func run(_ state: WindowState, _ sessions: ChatSessions) async {
        await PaletteProbe.settle(3000)  // launch work: the first window pass, the hidden quick panel build (+1 s)
        var setup: [String: Any] = ["tier": config.tier, "slot": sessions.environment.slot().key,
                                    "evilSlot": sessions.environment.evilSlot()?.key ?? NSNull(),
                                    "budgetB": EnginePolicy.current().map { Int64($0.budgetB) } ?? NSNull(),
                                    "backgroundRun": BackgroundRun.isOn, "pid": Int(getpid()), "skip": config.skip]
        watchSupervisor(sessions.environment.engine)
        // Evil Mode on (the S-24 sheet's Continue with the adult box ticked), as AT-FA-07 does.
        if let evil = EvilModeModel.shared {
            if !evil.isOn { evil.requestEnable() }
            if evil.showEnableSheet || !evil.isOn { try? evil.enable(adultSelfDeclared: true) }
            setup["evilOn"] = evil.isOn
        } else {
            setup["evilOn"] = false
        }
        let project = await prepareProject(sessions)
        setup["project"] = project.map { ["id": $0.id, "files": $0.files] } ?? NSNull()
        let images = makeImageQueue(sessions)
        setup["imageQueue"] = images != nil
        setup["setupS"] = elapsed()
        write(setup, "setup.json")
        event("setup", ok: true, extra: setup)
        let deadline = config.minutes * 60
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(config.sample_s))
                if Task.isCancelled { break }
                await sample("periodic")
            }
        }
        await sample("periodic")
        let soakStart = elapsed()
        var imagesDone = 0
        while elapsed() - soakStart < deadline {
            loop += 1
            phase = "sample"
            await PaletteProbe.settle(10_000)
            await sample("loop")
            let due = Int(((elapsed() - soakStart) / 3600 * config.images_per_hour).rounded(.down)) + 1
            if imagesDone < due, let images {
                phase = "image"
                await step("image") { await image(images) }
                imagesDone += 1
            }
            phase = "chat"
            let chatID = await step("chat") { await chat(state, sessions) }
            phase = "voice"
            await step("voice") { await voice(state, sessions) }
            phase = "evil"
            await step("evil") { await evilTurn(state, sessions) }
            phase = "normal"
            await step("normal") { await normalAgain(state, sessions, chatID: chatID) }
            phase = "quickpanel"
            await step("quickpanel") { await quickPanel() }
            phase = "project"
            if let project { await step("project") { await projectTurn(state, sessions, project) } }
            phase = "import"
            await step("import") { await importExport(sessions) }
        }
        phase = "end"
        sampler.cancel()
        await PaletteProbe.settle(10_000)
        await sample("loop")
        await sample("periodic")
        let hangs = watchdog.summary()
        let result: [String: Any] = [
            "minutes": config.minutes, "elapsedS": elapsed(), "loops": loop, "imagesDone": imagesDone, "counts": counts,
            "failures": failures, "errors": Array(errors.suffix(200)), "helperRestarts": helperRestarts,
            "hangsOver2s": hangs.over2, "hangsOver250ms": hangs.count, "hangMaxS": hangs.max,
            "metricKitPayloads": SoakMetricKit.shared.payloads, "metricKitHangsOver2s": SoakMetricKit.shared.hangsOver2s,
            "metricKitCrashes": SoakMetricKit.shared.crashes, "config": configJSON(), "completed": true,  // the verdict is soak-report.py's
        ]
        write(result, "result.json")
        log("done: \(loop) loops, \(imagesDone) images, failures \(failures), hangs > 2 s \(hangs.over2)")
    }

    /// Runs one leg, records ok/failed and its seconds.
    @discardableResult
    static func step<T>(_ name: String, _ body: () async -> T?) async -> T? {
        guard !config.skip.contains(name) else { return nil }
        let t = ContinuousClock.now
        let id = signposter.makeSignpostID()
        let st = signposter.beginInterval("soakStep", id: id)
        let r = await body()
        signposter.endInterval("soakStep", st)
        let s = PaletteProbe.seconds(ContinuousClock.now - t)
        counts[name, default: 0] += 1
        if r == nil { failures[name, default: 0] += 1 }
        event(name, ok: r != nil, extra: ["seconds": s])
        return r
    }

    static func event(_ name: String, ok: Bool, extra: [String: Any] = [:]) {
        var o = extra
        o["t"] = elapsed()
        o["loop"] = loop
        o["step"] = name
        o["ok"] = ok
        eventsWriter?.write(o)
    }

    static func fail(_ what: String) -> Bool {
        errors.append("loop \(loop) \(phase): \(what)")
        log("loop \(loop) \(phase): \(what)")
        event("error", ok: false, extra: ["phase": phase, "error": what])  // the app's stderr may go to its own log
        return false
    }

    static func write(_ obj: [String: Any], _ name: String) {
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
    }

    static func configJSON() -> [String: Any] {
        ["minutes": config.minutes, "sample_s": config.sample_s, "images_per_hour": config.images_per_hour,
         "image_mode": config.image_mode, "image_gb": config.image_gb, "image_quant": config.image_quant,
         "image_res": config.image_res, "tier": config.tier, "skip": config.skip]
    }

    /// Helper restarts (a crashed or killed helper: the supervisor reconnects).
    static func watchSupervisor(_ engine: any EngineService) {
        guard let s = engine as? EngineSupervisorClient else { return }
        Task { @MainActor in
            for await e in s.events() {
                let text = "\(e)"
                if text.lowercased().contains("restart") || text.lowercased().contains("crash") {
                    helperRestarts += 1
                    event("helperEvent", ok: false, extra: ["event": text])
                }
            }
        }
    }

    // MARK: Waiting

    /// 100 ms polling (the probes' 5 ms poll would add 8 h of main-thread wakeups to what the soak measures).
    static func waitUntil(timeout: Double, _ cond: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while true {
            if cond() { return true }
            if PaletteProbe.seconds(ContinuousClock.now - start) > timeout { return false }
            await PaletteProbe.settle(100)
        }
    }

    static func current(_ state: WindowState, _ sessions: ChatSessions) -> ConversationModel? {
        state.currentChatID.map(sessions.model(for:))
    }

    static func replyDone(_ m: ConversationModel?) -> Bool {
        guard let m, let last = m.messages.last, last.role == .assistant else { return false }
        return !m.isGenerating && last.status != .pending && last.status != .streaming
    }

    /// The last reply of `m` finished `done` with text: a saved message (ledger row); false otherwise.
    static func saved(_ m: ConversationModel?, leg: String) -> Bool {
        guard let m, let last = m.messages.last, last.role == .assistant else { return fail("\(leg): no reply") }
        guard last.status == .done, !last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail("\(leg): reply \(last.status.rawValue) \(last.errorCode ?? "") chars \(last.text.count) "
                + "generating \(m.isGenerating) messages \(m.messages.count)")
        }
        let sha = SHA256.hash(data: Data(last.text.utf8)).map { String(format: "%02x", $0) }.joined()
        savedWriter?.write(["chat": m.chatID, "message": last.id, "sha256": sha, "t": elapsed(), "leg": leg])
        return true
    }

    /// Sends `text` in the shown chat through the composer and waits for the reply.
    static func ask(_ text: String, _ state: WindowState, _ sessions: ChatSessions, leg: String) async -> Bool {
        // A person reads the reply before typing the next message: never send in the same instant a turn ended.
        await PaletteProbe.settle(2000)
        let before = current(state, sessions)?.messages.last { $0.role == .assistant }?.id
        sessions.composer.text = text
        guard sessions.composer.send() else { return fail("\(leg): send refused") }
        // The NEW reply (never the previous turn's, which is also `.assistant` and done).
        _ = await waitUntil(timeout: 30) {
            guard let last = current(state, sessions)?.messages.last, last.role == .assistant else { return false }
            return last.id != before
        }
        // …and its turn started: right after the send the turn is not active yet (it is handed to the TurnController
        // asynchronously, or held while the model loads), and a done-looking placeholder must not end the wait.
        _ = await waitUntil(timeout: 120) {
            guard let m = current(state, sessions), let last = m.messages.last, last.role == .assistant, last.id != before
            else { return false }
            return m.isGenerating || last.status == .error || last.status == .interrupted || !m.receivedText(of: last.id).isEmpty
        }
        guard await waitUntil(timeout: config.reply_timeout_s, { replyDone(current(state, sessions)) }) else {
            return fail("\(leg): no reply in \(Int(config.reply_timeout_s)) s")
        }
        return saved(current(state, sessions), leg: leg)
    }

    // MARK: Legs

    static let prompts = [
        "In two sentences, why is the sky blue?", "Give me three tips for keeping basil alive indoors.",
        "What is the difference between a list and a tuple in Python? Keep it short.",
        "Suggest a name for a small bakery that sells sourdough.", "Summarize the plot of Hamlet in three sentences.",
        "How many minutes are in a week? Show the arithmetic.", "Write a haiku about a quiet train station.",
        "What should I pack for a two-day hike in autumn? Bullet points.",
        "Explain what a hash map is to a ten-year-old.", "Translate 'good morning, how are you?' into French and Spanish.",
        "Give one example of a prime number between 50 and 60 and say why it is prime.",
        "What are two pros and two cons of working from home?",
    ]
    static let evilPrompts = [
        "Name three classic cocktails made with gin, one line each.", "Tell me a dark joke about Mondays.",
        "Roast my habit of leaving tabs open, in two sentences.", "Write a villain's one-line threat to a houseplant.",
    ]
    static let panelPrompts = ["What's 17 × 23?", "Capital of Australia?", "Synonym for 'quick'?", "How many legs does a spider have?"]
    static var promptIndex = 0
    static func nextPrompt(_ list: [String]) -> String {
        promptIndex += 1
        return list[promptIndex % list.count]
    }

    static func chat(_ state: WindowState, _ sessions: ChatSessions) async -> String? {
        state.newRegularChat()
        await PaletteProbe.settle(800)
        for i in 0..<3 {
            guard await ask(nextPrompt(prompts), state, sessions, leg: "chat\(i)") else { return nil }
        }
        return state.currentChatID
    }

    static func normalAgain(_ state: WindowState, _ sessions: ChatSessions, chatID: String?) async -> Bool? {
        if let chatID {
            state.open(.chat(chatID))
        } else {
            state.newRegularChat()
        }
        await PaletteProbe.settle(800)
        if sessions.composer.mode != .normal {
            sessions.composer.mode = .normal
            sessions.modeChanged(.normal)
        }
        return await ask(nextPrompt(prompts), state, sessions, leg: "normal") ? true : nil
    }

    static func evilTurn(_ state: WindowState, _ sessions: ChatSessions) async -> Bool? {
        guard EvilModeModel.shared?.isOn == true else { _ = fail("evil: Evil Mode off"); return nil }
        state.newEvilChat()
        // The composer takes the mode from its view; a background window may not update it (AT-FA-07's fallback).
        if !(await waitUntil(timeout: 3) { sessions.composer.mode == .evil }) {
            sessions.composer.mode = .evil
            sessions.modeChanged(.evil)
        }
        await PaletteProbe.settle(500)
        return await ask(nextPrompt(evilPrompts), state, sessions, leg: "evil") ? true : nil
    }

    /// One spoken question through the window's voice conversation (the launch's `-UseScriptedVoice` script).
    static func voice(_ state: WindowState, _ sessions: ChatSessions) async -> Bool? {
        state.newRegularChat()
        await PaletteProbe.settle(800)
        guard let start = sessions.composer.onStartVoice, let v = sessions.composer.voice else {
            _ = fail("voice: no voice controller (Voice models?)")
            return nil
        }
        let since = Date().timeIntervalSince1970
        start()
        var sawReply = false
        // The conversation's chat: the first utterance creates it (the controller keeps the nil chat it started with).
        func chat() -> String? { v.chatID ?? newestChat(sessions, since: since) }
        var phases: [String] = []
        // Done = the spoken question's reply finished in the chat; then the reply is spoken (the silent clock) and the
        // session returns to listening, which is waited for separately (its phase names vary with the route).
        let ok = await waitUntil(timeout: config.reply_timeout_s) {
            let p = "\(v.phase)"
            if phases.last != p { phases.append(p) }
            if v.phase.isError { return true }
            if v.phase == .thinking || v.phase == .speaking { sawReply = true }
            guard let id = chat() else { return false }
            let m = sessions.model(for: id)
            return replyDone(m) && !(m.messages.last?.text.isEmpty ?? true)
        }
        _ = await waitUntil(timeout: 120) {
            let p = "\(v.phase)"
            if phases.last != p { phases.append(p) }
            return v.phase == .listening || v.phase.isError
        }
        event("voicePhases", ok: true, extra: ["phases": Array(phases.prefix(40)), "sawReply": sawReply])
        let phaseText = "\(v.phase)"
        let errored = v.phase.isError
        let chatID = chat()
        v.end()
        _ = await waitUntil(timeout: 20) { v.phase == .idle }
        await PaletteProbe.settle(500)
        guard ok, !errored, let chatID else {
            _ = fail("voice: no spoken turn (phase \(phaseText), error \(v.lastError ?? "-"))")
            return nil
        }
        return saved(sessions.model(for: chatID), leg: "voice") ? true : nil
    }

    /// The newest chat row created since `since` (epoch s), if any.
    static func newestChat(_ sessions: ChatSessions, since: Double) -> String? {
        try? sessions.environment.database.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM chat WHERE created_at >= ? ORDER BY created_at DESC LIMIT 1",
                                arguments: [since - 1])
        }
    }

    static func quickPanel() async -> Bool? {
        let qp = QuickPanelController.shared
        guard await waitUntil(timeout: 10, { qp.window != nil }) else { _ = fail("quickpanel: not built"); return nil }
        qp.show(.menu)
        await PaletteProbe.settle(300)
        qp.model.text = nextPrompt(panelPrompts)
        guard qp.model.send() else { qp.hide(); _ = fail("quickpanel: send refused"); return nil }
        let done = await waitUntil(timeout: config.reply_timeout_s) { qp.model.phase == .done }
        let model = qp.model.chatID.flatMap { qp.conversation(for: $0) }
        _ = await waitUntil(timeout: 10) { replyDone(model) }
        qp.hide()
        await PaletteProbe.settle(300)
        guard done else { _ = fail("quickpanel: no reply"); return nil }
        return saved(model, leg: "quickpanel") ? true : nil
    }

    struct SoakProject {
        var id: String
        var files: Int
        var questions: [String]
    }

    /// The qa-50 documents linked as one project folder (indexed once, before the soak clock starts).
    static func prepareProject(_ sessions: ChatSessions) async -> SoakProject? {
        guard !config.skip.contains("project") else { return nil }
        let root = URL(fileURLWithPath: config.fixtures).appendingPathComponent("projects/qa-50")
        let questions = ((try? String(contentsOf: root.appendingPathComponent("questions.jsonl"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { line -> String? in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["q"] as? String
            }
        guard !questions.isEmpty else { _ = fail("project: no \(root.path)/questions.jsonl"); return nil }
        let db = sessions.environment.database
        do {
            let project = try ProjectStore(database: db).create(name: "Soak project")
            let t = ContinuousClock.now
            let scan = try await ProjectsModel.indexer(db).link(root.appendingPathComponent("docs", isDirectory: true), to: project.id)
            event("projectIndex", ok: true, extra: ["seconds": PaletteProbe.seconds(ContinuousClock.now - t), "indexed": scan.indexed])
            return SoakProject(id: project.id, files: scan.indexed, questions: questions)
        } catch {
            _ = fail("project: \(error)")
            return nil
        }
    }

    static func projectTurn(_ state: WindowState, _ sessions: ChatSessions, _ p: SoakProject) async -> Bool? {
        state.newChat(inProject: p.id)
        await PaletteProbe.settle(800)
        return await ask(p.questions[loop % p.questions.count], state, sessions, leg: "project") ? true : nil
    }

    static func importExport(_ sessions: ChatSessions) async -> Bool? {
        let files = ["chats/chatgpt-export/export.zip", "chats/claude-export/export.zip"]
        let url = URL(fileURLWithPath: config.fixtures).appendingPathComponent(files[loop % files.count])
        guard FileManager.default.fileExists(atPath: url.path) else { _ = fail("import: no \(url.path)"); return nil }
        let c = ImportCoordinator(database: sessions.environment.database)
        var summary: ImportSummary?
        var failure: String?
        for await e in c.start(url) {
            switch e {
            case .finished(let s): summary = s
            case .failed(let key): failure = key
            default: break
            }
            if summary != nil || failure != nil { break }
        }
        if let failure { _ = fail("import: \(failure)"); return nil }
        guard let summary else { _ = fail("import: no summary"); return nil }
        event("importSummary", ok: true, extra: ["chats": summary.chats, "messages": summary.messages, "skipped": summary.skipped])
        return true
    }

    // MARK: Images

    struct ImageQueue {
        var queue: MediaJobQueue
        var chatID: String
        var xfer: URL
    }

    /// A job queue of its own (its own small database; the app's queue only takes the installed Photo pack's jobs) on
    /// the app's helper transport, with the dev ChildSafetyCheck detectors (BenchMode.benchSafety).
    static func makeImageQueue(_ sessions: ChatSessions) -> ImageQueue? {
        guard !config.skip.contains("image") else { return nil }
        guard let transport = EngineServices.mediaTransport(for: sessions.environment.engine) else {
            _ = fail("image: no media transport")
            return nil
        }
        do {
            let work = dir.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let db = try AppDatabase.onDisk(at: work.appendingPathComponent("images.sqlite"))
            let chat = ChatRecord(mode: .normal)
            try db.write { try chat.insert($0) }
            let xfer = work.appendingPathComponent("xfer", isDirectory: true)
            let q = MediaJobQueue(database: db, transport: transport, xferRoot: xfer, safety: { BenchMode.benchSafety })
            return ImageQueue(queue: q, chatID: chat.id, xfer: xfer)
        } catch {
            _ = fail("image: \(error)")
            return nil
        }
    }

    static let imageSubjects = ["a lighthouse at dusk", "a red cube on a wooden table, studio light", "a bowl of lemons on linen",
                                "a mountain lake at sunrise", "a paper boat on a puddle", "a cat asleep on a windowsill"]

    static func image(_ q: ImageQueue) async -> Bool? {
        let res = config.image_res
        var model = DevModels.imageSet(config.image_quant, res: res)
        if config.image_mode == "scripted" {  // the T05 mini-soak's footprint workload (ScriptedImageEngine buffers)
            model = ImageModelSet(key: "scripted-image", diffusionModel: "scripted:6:100", llm: "", vae: "",
                                  footprintBytes: UInt64(config.image_gb * 1e9))
        }
        let req = ImageRequest(model: model, prompt: imageSubjects[loop % imageSubjects.count], width: res, height: res,
                               steps: 4, seed: Int64(loop), preview: "none", outputPath: "")
        do {
            let id = try await q.queue.enqueue(chatID: q.chatID, image: req)
            let u = await q.queue.finished(id)
            if let p = u.resultPath { try? FileManager.default.removeItem(atPath: p) }
            try? FileManager.default.removeItem(at: q.xfer.appendingPathComponent(id))
            guard u.state == .done else { _ = fail("image: \(u.state.rawValue) \(u.errorCode ?? "")"); return nil }
            return true
        } catch {
            _ = fail("image: \(error)")
            return nil
        }
    }

    // MARK: Samples

    static func children(_ pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 256)
        let bytes = buf.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(pid), $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return Array(buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : "?"
    }

    static func vmStats() -> [String: UInt64] {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return [:] }
        return ["swapouts": UInt64(stats.swapouts), "swapins": UInt64(stats.swapins), "pageouts": UInt64(stats.pageouts),
                "compressions": UInt64(stats.compressions)]
    }

    static func helperProbe(_ engine: any EngineService) async -> HelperProbe? {
        let client = (engine as? EngineSupervisorClient)?.current ?? (engine as? EngineClient)
        guard let client else { return nil }
        return try? await client.probe()
    }

    static let appDevice = MTLCreateSystemDefaultDevice()

    static func sample(_ kind: String) async {
        let probe: HelperProbe? = if let engine { await helperProbe(engine) } else { nil }
        let me = getpid()
        let appFp = BenchMode.physFootprint(me)
        let helper = probe.map { pid_t($0.pid) } ?? 0
        let helperFp = helper > 0 ? BenchMode.physFootprint(helper) : 0
        let kids = children(helper).map { (pid: $0, name: name($0), fp: BenchMode.physFootprint($0)) }
        let kidsFp = kids.reduce(UInt64(0)) { $0 + $1.fp }
        let mtlHelper = probe?.mtlAllocatedBytes ?? 0
        let mtlApp = UInt64(appDevice?.currentAllocatedSize ?? 0)
        let hangs = watchdog.summary()
        var o: [String: Any] = [
            "kind": kind, "t": elapsed(), "loop": loop, "phase": phase, "date": ISO8601DateFormatter().string(from: Date()),
            "app_pid": Int(me), "app_fp": appFp, "helper_pid": Int(helper), "helper_fp": helperFp, "children_fp": kidsFp,
            "children": kids.map { ["pid": Int($0.pid), "name": $0.name, "fp": $0.fp] as [String: Any] },
            "mtl_helper": mtlHelper, "mtl_app": mtlApp, "footprint_total": appFp + helperFp + kidsFp,
            "footprint_plus_metal": appFp + helperFp + kidsFp + mtlHelper + mtlApp,
            "resident_models": probe?.residentModels ?? [], "hangs_over_250ms": hangs.count, "hangs_over_2s": hangs.over2,
            "hang_max_s": hangs.max, "helper_restarts": helperRestarts,
        ]
        for (k, v) in vmStats() { o["vm_\(k)"] = v }
        samplesWriter?.write(o)
        write(["app_pid": Int(me), "helper_pid": Int(helper), "children": kids.map { Int($0.pid) }, "loop": loop, "phase": phase,
               "t": elapsed()], "status.json")
    }
}

// MARK: - Main-thread hang watchdog

/// Pings the main queue every 250 ms from its own thread; a stall ≥ 250 ms is a `mainThreadHang` signpost interval and a
/// `hangs.jsonl` row (start uptime, seconds, the soak phase). The soak fails on any stall > 2 s.
/// While a stall lasts the watchdog also samples the main thread every 50 ms (`HangStackSampler`) and, once it passes
/// `stackThresholdS`, takes one snapshot of every thread. A stall that ends at or above the threshold gets a call tree in
/// `hang-stacks/<n>.txt` and the row says where the main thread was (`where`: its deepest own-code frame in most samples),
/// how much CPU it used (`main_cpu_s`: ≈ seconds → it was computing; ≈ 0 → it waited or was not scheduled), its
/// run states and scheduling priorities over the samples. Measuring is unchanged: the stall ends when the main queue
/// runs the ping, whether or not it was sampled meanwhile.
final class HangWatchdog: @unchecked Sendable {
    static let stackThresholdS = 1.0
    private let lock = NSLock()
    private var running = false
    private var count = 0
    private var over2 = 0
    private var maxS = 0.0
    private var phase = "setup"
    private var out: FileHandle?
    private var stacksDir: URL?
    private let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "soak")

    func start(dir file: URL) {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        out = FileHandle(forWritingAtPath: file.path)
        stacksDir = file.deletingLastPathComponent().appendingPathComponent("hang-stacks", isDirectory: true)
        lock.withLock { running = true }
        // Called on the main thread (SoakProbe.start): its Mach port is what the sampler suspends and reads.
        let main = Thread.isMainThread ? pthread_mach_thread_np(pthread_self()) : 0
        let t = Thread { [self] in loop(mainThread: main) }
        t.name = "soak.hang-watchdog"
        t.qualityOfService = .userInteractive
        t.start()
    }

    func stop() { lock.withLock { running = false } }

    func setPhase(_ p: String) { lock.withLock { phase = p } }

    func summary() -> (count: Int, over2: Int, max: Double) { lock.withLock { (count, over2, maxS) } }

    private func loop(mainThread: thread_act_t) {
        let sampler = HangStackSampler(mainThread: mainThread)
        var stacksWritten = 0
        while lock.withLock({ running }) {
            let sem = DispatchSemaphore(value: 0)
            let sent = DispatchTime.now()
            DispatchQueue.main.async { sem.signal() }
            if sem.wait(timeout: sent + .milliseconds(250)) == .timedOut {
                let id = signposter.makeSignpostID()
                let state = signposter.beginInterval("mainThreadHang", id: id)
                let phaseAtStart = lock.withLock { phase }
                sampler.begin()
                while sem.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
                    sampler.sampleMain()
                    let soFar = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e9
                    if soFar >= Self.stackThresholdS { sampler.snapshotAllThreadsOnce(atS: soFar) }
                }
                let s = Double(DispatchTime.now().uptimeNanoseconds - sent.uptimeNanoseconds) / 1e9
                signposter.endInterval("mainThreadHang", state)
                lock.withLock {
                    count += 1
                    if s > 2 { over2 += 1 }
                    maxS = max(maxS, s)
                }
                var row: [String: Any] = ["uptime_s": Double(sent.uptimeNanoseconds) / 1e9, "seconds": s,
                                          "date": ISO8601DateFormatter().string(from: Date()), "phase": phaseAtStart]
                if s >= Self.stackThresholdS, let dir = stacksDir {
                    stacksWritten += 1
                    let name = String(format: "%04d-%.2fs-%@.txt", stacksWritten, s, phaseAtStart)
                    let report = sampler.finish(seconds: s, phase: phaseAtStart)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try? Data(report.text.utf8).write(to: dir.appendingPathComponent(name))
                    row["stack_file"] = "hang-stacks/\(name)"
                    for (k, v) in report.fields { row[k] = v }
                } else {
                    sampler.discard()
                }
                if let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                    out?.write(d + Data("\n".utf8))
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

/// In-process backtraces for the hang watchdog (soak/perf-harness builds only: this file is `#if DEBUG ||
/// ANTICHAT_PERF_HARNESS`). A thread is suspended only while its registers and frame records (the arm64 frame-pointer
/// chain, read with `vm_read_overwrite` so a bad pointer cannot fault) are copied into a preallocated buffer: nothing in
/// that window allocates or takes a lock the suspended thread might hold. Symbols (`dladdr`, demangled) are resolved
/// after it resumes. Runs only on the watchdog thread.
final class HangStackSampler {
    static let maxFrames = 160
    private let buf = UnsafeMutablePointer<UInt64>.allocate(capacity: maxFrames)
    private let mainThread: thread_act_t
    private let selfThread: thread_act_t = pthread_mach_thread_np(pthread_self())  // created on the watchdog thread
    private var samples: [[UInt64]] = []
    private var states: [String: Int] = [:]
    private var priorities: [Int32] = []
    private var cpuAtStart: UInt64 = 0
    private var snapshot: String?
    private var symbols: [UInt64: (text: String, own: Bool)] = [:]
    private let ownImage = Bundle.main.executablePath ?? ""
    private let ownBundle = Bundle.main.bundlePath + "/"

    init(mainThread: thread_act_t) { self.mainThread = mainThread }

    func begin() {
        samples.removeAll(keepingCapacity: true)
        states.removeAll()
        priorities.removeAll()
        snapshot = nil
        cpuAtStart = Self.info(mainThread).map { $0.pth_user_time + $0.pth_system_time } ?? 0
        sampleMain()
    }

    func discard() { samples.removeAll(keepingCapacity: true) }

    func sampleMain() {
        guard mainThread != 0 else { return }
        let frames = backtrace(mainThread)
        if !frames.isEmpty { samples.append(frames) }
        if let i = Self.info(mainThread) {
            states[Self.runState(i.pth_run_state), default: 0] += 1
            priorities.append(i.pth_curpri)
        }
    }

    /// Every other thread's stack once per stall (who holds what the main thread waits for).
    func snapshotAllThreadsOnce(atS s: Double) {
        guard snapshot == nil else { return }
        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list else { snapshot = ""; return }
        var text = String(format: "\n== all threads at %.2f s ==\n", s)
        for k in 0..<Int(n) {
            let t = list[k]
            if t != selfThread && t != mainThread {
                let info = Self.info(t)
                let frames = backtrace(t)
                let name = info.map { Self.name($0) } ?? ""
                let cpu = info.map { Double($0.pth_user_time + $0.pth_system_time) / 1e9 } ?? 0
                text += String(format: "\n-- thread %d %@ state %@ pri %d cpu %.2f s\n", k, name,
                               info.map { Self.runState($0.pth_run_state) } ?? "?", info?.pth_curpri ?? -1, cpu)
                for a in frames { text += "    \(symbol(a).text)\n" }
            }
            mach_port_deallocate(mach_task_self_, t)
        }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                      vm_size_t(Int(n) * MemoryLayout<thread_act_t>.stride))
        text += Self.machineSnapshot()
        snapshot = text
    }

    /// The load average and the busiest processes with their priorities. A main thread that is runnable but gets
    /// little CPU loses to these (starvation, not work of its own).
    private static func machineSnapshot() -> String {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        var text = String(format: "\n== machine: load %.1f %.1f %.1f, %d CPUs; busiest processes (ps %%cpu pri) ==\n",
                          load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "pid,pcpu,pri,comm", "-r"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return text + "  (ps failed)\n" }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for line in out.split(separator: "\n").prefix(16) { text += "  \(line)\n" }
        return text
    }

    /// The stall's report: a call tree of the main-thread samples (root first, like `sample`) + the thread snapshot,
    /// and the row's fields.
    func finish(seconds: Double, phase: String) -> (text: String, fields: [String: Any]) {
        let cpuEnd = Self.info(mainThread).map { $0.pth_user_time + $0.pth_system_time } ?? cpuAtStart
        let cpu = Double(cpuEnd &- cpuAtStart) / 1e9
        // Where: the deepest own-code frame of each sample, the most common one.
        var whereCounts: [String: Int] = [:]
        for s in samples {
            if let own = s.first(where: { symbol($0).own }) { whereCounts[symbol(own).text, default: 0] += 1 }
        }
        let top = whereCounts.sorted { $0.value > $1.value }
        var fields: [String: Any] = ["main_cpu_s": (cpu * 1000).rounded() / 1000, "samples": samples.count,
                                     "main_states": states]
        if let lo = priorities.min(), let hi = priorities.max() { fields["main_pri"] = [lo, hi] }
        if let w = top.first { fields["where"] = w.key; fields["where_n"] = w.value }
        if top.count > 1 { fields["where_next"] = top.dropFirst().prefix(3).map { "\($0.value)× \($0.key)" } }
        let pri = Dictionary(priorities.map { ($0, 1) }, uniquingKeysWith: +).sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        var text = String(format: "main-thread stall %.3f s, phase %@, %d samples / 50 ms, main CPU %.3f s, states %@, "
                          + "curpri %@\n", seconds, phase, samples.count, cpu, "\(states)", pri)
        text += "\n== own-code frame on top (deepest AntiChat frame per sample) ==\n"
        for (k, v) in top.prefix(15) { text += "  \(v)  \(k)\n" }
        text += "\n== main thread call tree (root first; count = samples) ==\n"
        text += callTree()
        text += snapshot ?? ""
        samples.removeAll(keepingCapacity: true)
        return (text, fields)
    }

    private final class Node {
        var count = 0
        var children: [UInt64: Node] = [:]
        var order: [UInt64] = []
    }

    private func callTree() -> String {
        let root = Node()
        for s in samples {
            var node = root
            for a in s.reversed() {
                let next: Node
                if let c = node.children[a] { next = c } else { next = Node(); node.children[a] = next; node.order.append(a) }
                next.count += 1
                node = next
            }
        }
        var out = ""
        func emit(_ n: Node, _ depth: Int) {
            for a in n.order.sorted(by: { n.children[$0]!.count > n.children[$1]!.count }) {
                let c = n.children[a]!
                out += String(repeating: " ", count: min(depth, 80)) + "\(c.count) \(symbol(a).text)\n"
                emit(c, depth + 1)
            }
        }
        emit(root, 0)
        return out
    }

    // MARK: Frames

    /// pc, lr, then the frame-pointer chain of `thread` (leaf first); [] when it cannot be read.
    private func backtrace(_ thread: thread_act_t) -> [UInt64] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        let n = walk(thread)
        thread_resume(thread)
        return Array(UnsafeBufferPointer(start: buf, count: n))
    }

    private func walk(_ thread: thread_act_t) -> Int {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var n = 0
        let pc = Self.strip(state.__pc)
        if pc != 0 { buf[n] = pc; n += 1 }
        let lr = Self.strip(state.__lr)
        if lr != 0 { buf[n] = lr; n += 1 }
        var fp = state.__fp
        var record: (UInt64, UInt64) = (0, 0)
        while fp != 0, fp & 7 == 0, n < Self.maxFrames {
            var size: vm_size_t = 0
            let rk = withUnsafeMutablePointer(to: &record) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &size)
            }
            guard rk == KERN_SUCCESS, size == 16 else { break }
            let ret = Self.strip(record.1)
            if ret == 0 { break }
            // A leaf that already pushed its frame record returns to lr: keep it once.
            if !(n == 2 && lr != 0 && ret == lr) { buf[n] = ret; n += 1 }
            guard record.0 > fp else { break }
            fp = record.0
        }
        return n
        #else
        return 0
        #endif
    }

    /// Strips pointer-authentication bits (system libraries are arm64e) off a code address.
    private static func strip(_ a: UInt64) -> UInt64 { a & 0x0000_7FFF_FFFF_FFFF }

    // MARK: Thread info

    private static func info(_ thread: thread_act_t) -> thread_extended_info? {
        var info = thread_extended_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    private static func runState(_ s: Int32) -> String {
        switch s {
        case TH_STATE_RUNNING: "running"  // running or runnable (waiting for a CPU)
        case TH_STATE_STOPPED: "stopped"
        case TH_STATE_WAITING: "waiting"
        case TH_STATE_UNINTERRUPTIBLE: "uninterruptible"
        case TH_STATE_HALTED: "halted"
        default: "state\(s)"
        }
    }

    private static func name(_ i: thread_extended_info) -> String {
        withUnsafeBytes(of: i.pth_name) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: Symbols

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                 UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    /// `image  symbol + offset` for a return address (looked up at address − 1: inside the call), cached.
    private func symbol(_ a: UInt64) -> (text: String, own: Bool) {
        if let s = symbols[a] { return s }
        var info = Dl_info()
        var result = (text: String(format: "0x%llx", a), own: false)
        if a > 1, dladdr(UnsafeRawPointer(bitPattern: UInt(a - 1)), &info) != 0, let f = info.dli_fname {
            let path = String(cString: f)
            let image = (path as NSString).lastPathComponent
            let own = path == ownImage || path.hasPrefix(ownBundle) && !path.contains("/Contents/Helpers/")
            if let s = info.dli_sname, let base = info.dli_saddr {
                let raw = String(cString: s)
                var name = raw
                if let d = Self.demangle, let out = d(s, strlen(s), nil, nil, 0) {
                    name = String(cString: out)
                    free(out)
                }
                if name.count > 400 { name = String(name.prefix(400)) + "…" }
                result = ("\(image)  \(name) + \(a - UInt64(UInt(bitPattern: base)))", own)
            } else if let base = info.dli_fbase {
                result = (String(format: "%@  0x%llx", image, a - UInt64(UInt(bitPattern: base))), own)
            }
        }
        symbols[a] = result
        return result
    }
}

// MARK: - MetricKit

/// Keeps every MetricKit diagnostic payload delivered during the soak (hang and crash diagnostics; on macOS they are
/// often delivered at the next launch, which tools/perf/crash-free.py also reads from the containers' Diagnostics/).
final class SoakMetricKit: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = SoakMetricKit()
    private let lock = NSLock()
    private var dir: URL?
    private(set) var payloads = 0
    private(set) var hangsOver2s = 0
    private(set) var crashes = 0

    func start(dir: URL) {
        lock.withLock { self.dir = dir }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ list: [MXDiagnosticPayload]) {
        guard let dir = lock.withLock({ dir }) else { return }
        for (i, p) in list.enumerated() {
            let ts = Int(p.timeStampEnd.timeIntervalSince1970)
            try? p.jsonRepresentation().write(to: dir.appendingPathComponent("diag-\(ts)-\(i).json"), options: .atomic)
            let long = (p.hangDiagnostics ?? []).filter { $0.hangDuration.converted(to: .seconds).value > 2 }.count
            lock.withLock {
                payloads += 1
                hangsOver2s += long
                crashes += p.crashDiagnostics?.count ?? 0
            }
        }
    }
}
#endif
