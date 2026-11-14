// M1.T05 step 6: the ScriptedEngine replays JSONL scripts as the seven-event contract (+ lifecycle).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import os
import Testing
@testable import AntiChatEngines

enum ScriptFixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// `fixtures/scripts` (fixtures repo) when populated, else the in-repo staging copy `tools/fixtures/scripts`
    /// (A-M1-T05a: the fixtures submodule was not writable from the T05 worktree).
    static var dir: URL {
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty {
            let d = URL(fileURLWithPath: env).appendingPathComponent("scripts")
            if FileManager.default.fileExists(atPath: d.appendingPathComponent("basic.jsonl").path) { return d }
        }
        let f = repoRoot.appendingPathComponent("fixtures/scripts")
        if FileManager.default.fileExists(atPath: f.appendingPathComponent("basic.jsonl").path) { return f }
        return repoRoot.appendingPathComponent("tools/fixtures/scripts")
    }

    static func url(_ name: String) -> URL { dir.appendingPathComponent("\(name).jsonl") }

    static let expected = [
        "basic", "stream-600w", "tool-call", "reasoning", "crash-mid-stream", "slow-load", "s2", "tool-loop-runaway",
        "long-context", "no-reasoning",
    ]
}

final class OutputLog: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [AdapterOutput]())
    func add(_ o: AdapterOutput) { lock.withLock { $0.append(o) } }
    var all: [AdapterOutput] { lock.withLock { $0 } }
    var events: [EngineEvent] { all.compactMap { if case .event(let e) = $0 { e } else { nil } } }
    var lifecycle: [LifecycleEvent] { all.compactMap { if case .lifecycle(let l) = $0 { l } else { nil } } }
    var text: String { events.compactMap { if case .textDelta(let s) = $0 { s } else { nil } }.joined() }
}

@Suite struct ScriptedEngineTests {
    static func run(_ engine: ScriptedEngine, _ req: ChatRequest) async throws -> OutputLog {
        try await engine.load(req.modelSlot)
        let log = OutputLog()
        for await o in try await engine.generate(req, context: GenerationContext()) { log.add(o) }
        return log
    }

    static func inline(_ text: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("scripted-\(UUID().uuidString).jsonl")
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    static func req(_ script: URL, assistantTurns: Int = 0) -> ChatRequest {
        var msgs = [ChatMessage(role: .user, content: "hello there, engine")]
        for i in 0..<assistantTurns {
            msgs += [ChatMessage(role: .assistant, content: "a\(i)"), ChatMessage(role: .user, content: "q\(i)")]
        }
        return ChatRequest(modelSlot: .scripted(script.path), messages: msgs)
    }

    @Test func everyFixtureScriptParses() throws {
        for name in ScriptFixtures.expected {
            let s = try EngineScript(contentsOf: ScriptFixtures.url(name))
            #expect(!s.segments.isEmpty && !s.segments[0].isEmpty, "\(name) is empty")
        }
        #expect(try EngineScript(contentsOf: ScriptFixtures.url("no-reasoning")).capabilities.reasoning == false)
        #expect(try EngineScript(contentsOf: ScriptFixtures.url("tool-call")).segments.count == 2)
    }

    @Test func basicStreamsTextThenUsageThenOneTerminal() async throws {
        let log = try await Self.run(ScriptedEngine(), Self.req(ScriptFixtures.url("basic")))
        #expect(log.text == "Hello! How can I help you today?")
        #expect(log.events.filter(\.isTerminal) == [.done(.stop)])
        #expect(log.events.last == .done(.stop))
        guard case .usage(let u)? = log.events.dropLast().last else { Issue.record("usage before done"); return }
        #expect(u.completionTokens == 7)
        #expect(u.promptTokens > 0)
    }

    @Test func toolCallTurnThenAnswerTurn() async throws {
        let e = ScriptedEngine()
        let first = try await Self.run(e, Self.req(ScriptFixtures.url("tool-call")))
        #expect(first.events.contains(.toolCallDelta(id: "call_1", name: "echo", argsFragment: "{\"text\":")))
        #expect(first.events.contains(.toolCallDelta(id: "call_1", name: nil, argsFragment: "\"hello\"}")))
        #expect(first.events.contains(.toolCallDone(id: "call_1", name: "echo", argsJSON: "{\"text\":\"hello\"}")))
        #expect(first.events.last == .done(.toolCalls))
        let second = try await Self.run(e, Self.req(ScriptFixtures.url("tool-call"), assistantTurns: 1))
        #expect(second.text == "The tool answered: hello.")
        #expect(second.events.last == .done(.stop))
    }

    @Test func runawayLoopSubstitutesTheStepNumber() async throws {
        let e = ScriptedEngine()
        for k in 0..<3 {
            let log = try await Self.run(e, Self.req(ScriptFixtures.url("tool-loop-runaway"), assistantTurns: k))
            #expect(log.events.contains(.toolCallDone(id: "call_\(k + 1)", name: "echo", argsJSON: "{\"text\":\"step \(k + 1)\"}")))
            #expect(log.events.last == .done(.toolCalls))
        }
    }

    @Test func crashCallsTheCrashHandlerWithoutATerminal() async throws {
        let crashed = OSAllocatedUnfairLock(initialState: 0)
        let e = ScriptedEngine(onCrash: { crashed.withLock { $0 += 1 } })
        let log = try await Self.run(e, Self.req(ScriptFixtures.url("crash-mid-stream")))
        #expect(crashed.withLock { $0 } == 1)
        #expect(log.events.filter(\.isTerminal).isEmpty)
        #expect(!log.text.isEmpty)
    }

    @Test func errorStepMapsToTheM1Code() async throws {
        let u = try Self.inline(#"{"t":"textDelta","v":"a"}"# + "\n" + #"{"t":"error","code":"model.notEnoughMemory"}"#)
        let log = try await Self.run(ScriptedEngine(), Self.req(u))
        guard case .error(let err)? = log.events.last else { Issue.record("no error"); return }
        #expect(err.is(.modelNotEnoughMemory))
        #expect(err.userMessageKey == "model.notEnoughMemory")
    }

    @Test func loadRunsOnceWithProgress() async throws {
        let u = try Self.inline(#"{"t":"load","ms":100,"steps":4}"# + "\n" + #"{"t":"textDelta","v":"ok"}"#)
        let e = ScriptedEngine()
        let first = try await Self.run(e, Self.req(u))
        #expect(first.lifecycle == [.loadState(.loading), .loadProgress(0.25), .loadProgress(0.5), .loadProgress(0.75), .loadProgress(1), .loadState(.ready)])
        let second = try await Self.run(e, Self.req(u))
        #expect(second.lifecycle.isEmpty)
        #expect(second.text == "ok")
    }

    @Test func warmupLoadsAndConcurrentChatWaitsForReady() async throws {
        let script = try EngineScript(text: #"{"t":"load","ms":200,"steps":4}"# + "\n" + #"{"t":"textDelta","v":"ok"}"#)
        let p = EngineScriptPlayer(script: script)
        let warm = Task { try await p.warmup { _ in } }
        try await Task.sleep(for: .milliseconds(30))
        let log = OutputLog()
        let t0 = ContinuousClock.now
        await p.play(Self.req(URL(fileURLWithPath: "/unused"))) { o in
            if case .engine(let e) = o { log.add(.event(e)) }
            if case .lifecycle(let l) = o { log.add(.lifecycle(l)) }
        }
        try await warm.value
        #expect(ContinuousClock.now - t0 >= .milliseconds(120))
        #expect(log.lifecycle.first == .loadState(.loading))
        #expect(log.lifecycle.last == .loadState(.ready))
        #expect(log.text == "ok")
        #expect(await p.loaded)
    }

    @Test func cancellationEndsWithDoneCancelledPromptly() async throws {
        let e = ScriptedEngine()
        let req = Self.req(ScriptFixtures.url("stream-600w"))
        try await e.load(req.modelSlot)
        let log = OutputLog()
        let stream = try await e.generate(req, context: GenerationContext())
        let consumer = Task {
            for await o in stream {
                log.add(o)
                if log.events.count == 3 { break }
            }
        }
        await consumer.value
        // Breaking out of the loop terminates the stream, which cancels the player.
        let p = try await e.player(req.modelSlot.path)
        let log2 = OutputLog()
        let t = Task {
            await p.play(req) { o in if case .engine(let ev) = o { log2.add(.event(ev)) } }
        }
        try await Task.sleep(for: .milliseconds(120))
        t.cancel()
        await t.value
        // Promptly = the player stopped where it was cancelled (progress, not elapsed time: a loaded host stretches
        // both): the 600-word script did not play on, and nothing followed the terminal event.
        let atCancel = log2.events.count
        #expect(log2.events.filter(\.isDelta).count < 600, "the script played on after the cancel")
        try await Task.sleep(for: .milliseconds(50))
        #expect(log2.events.count == atCancel, "events after the cancelled play returned")
        #expect(log2.events.last == .done(.cancelled))
        #expect(log2.events.filter(\.isTerminal).count == 1)
    }

    @Test func capsHeaderOverridesCapabilities() throws {
        let s = try EngineScript(text: #"{"t":"caps","reasoning":false,"vision":true,"contextTokens":4096}"# + "\n" + #"{"t":"textDelta","v":"x"}"#)
        #expect(s.hasCapsHeader)
        #expect(s.capabilities.reasoning == false)
        #expect(s.capabilities.vision == true)
        #expect(s.capabilities.contextTokens == 4096)
    }

    /// Q-015 r5: `when` keeps a step only for a request whose last user message contains its text.
    @Test func whenPicksStepsByTheUsersWords() throws {
        let s = try EngineScript(text: [#"{"t":"textDelta","v":"first"}"#, #"{"t":"turn"}"#,
                                        #"{"t":"textDelta","v":"answer","when":"Budget"}"#,
                                        #"{"t":"toolCallDone","id":"c","name":"t","args":"{}","when":"total row"}"#].joined(separator: "\n"))
        func kinds(_ user: String) -> [EngineScript.Step.Kind] {
            let r = ChatRequest(modelSlot: .scripted("x"), messages: [ChatMessage(role: .user, content: "q"),
                                                                       ChatMessage(role: .assistant, content: "a"),
                                                                       ChatMessage(role: .user, content: user)])
            return s.segment(for: r).steps.map(\.kind)
        }
        #expect(kinds("Make a budget sheet") == [.text("answer", tokens: 1)])
        #expect(kinds("Add a TOTAL ROW") == [.toolCallDone(id: "c", name: "t", args: "{}")])
        #expect(kinds("something else").isEmpty)
    }

    /// fix/overlay-field-focus: the image-edit chat of the UI tests (App/UITests/ImageEditTests.editChat, same lines).
    /// Its old [create][edit] form played the edit in turn 1's tool step (no picture in focus: source "") and, the
    /// tool-only reply dropped from later prompts, every later turn created a new picture: no edit ever made a version,
    /// so the viewer had no version rail. Each request of the journey must now play the call a model would make.
    @Test func imageEditChatScriptEditsThePictureInFocus() async throws {
        let script = try EngineScript(text: [
            #"{"t":"toolCallDone","id":"call_1","name":"create_image","args":"{\"prompt\":\"a lighthouse at dusk\",\"aspect\":\"3:2\"}","delayMs":1}"#,
            #"{"t":"turn"}"#,
            #"{"t":"toolCallDone","id":"call_e{{n}}","name":"edit_image","args":"{\"prompt\":\"make the sky purple\",\"source_image_id\":\"{{image}}\"}","delayMs":1,"when":"sky purple"}"#,
            #"{"t":"textDelta","v":"Here it is.","delayMs":1}"#,
            #"{"t":"turn"}"#,
            #"{"t":"textDelta","v":"Done.","delayMs":1}"#,
        ].joined(separator: "\n"))
        let player = EngineScriptPlayer(script: script, sleep: { _ in })
        final class Box: @unchecked Sendable { var calls: [(String, String)] = []; var text = "" }
        func play(_ messages: [ChatMessage], context: String? = nil, forced: String? = nil) async -> Box {
            var r = ChatRequest(modelSlot: .scripted("x"), messages: messages, toolChoice: forced.map { .function($0) })
            r.turnContext = context
            let box = Box()
            await player.play(r) { out in
                if case .engine(.toolCallDone(_, let name, let args)) = out { box.calls.append((name, args)) }
                if case .engine(.textDelta(let t)) = out { box.text += t }
            }
            return box
        }
        func source(_ args: String) -> String? {
            ((try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any])?["source_image_id"] as? String
        }
        let u1 = ChatMessage(role: .user, content: "Draw me a lighthouse at dusk")
        let step = ChatMessage(role: .assistant, content: "")
        // Turn 1 creates the picture; its tool step answers in text (no edit: nothing is in focus yet).
        #expect(await play([u1]).calls.map(\.0) == ["create_image"])
        let t1Step = await play([u1, step, ChatMessage(role: .tool, content: "{}")])
        #expect(t1Step.calls.isEmpty && t1Step.text == "Here it is.")
        // Turn 2: a plain message edits the picture its context line names (the newest version = the artifact id).
        let a1 = ChatMessage(role: .assistant, content: "Here it is."), u2 = ChatMessage(role: .user, content: "Make the sky purple")
        let t2 = await play([u1, a1, u2], context: #"Picture in focus: a picture made in this chat, image_id "art1"."#)
        #expect(t2.calls.map(\.0) == ["edit_image"] && t2.calls.first.map { source($0.1) } == "art1")
        let t2Step = await play([u1, a1, u2, step, ChatMessage(role: .tool, content: "{}")])
        #expect(t2Step.calls.isEmpty, "the edit turn's tool step answers in text")
        // Turn 3: the viewer's Describe the change on v1 (a forced edit_image) edits the version the turn names.
        let a2 = ChatMessage(role: .assistant, content: "Here it is. Done."), u3 = ChatMessage(role: .user, content: "Add a moon")
        let t3 = await play([u1, a1, u2, a2, u3], context: #"Picture in focus: … (version 1 of 2), image_id "ver1"."#, forced: "edit_image")
        #expect(t3.calls.map(\.0) == ["edit_image"] && t3.calls.first.map { source($0.1) } == "ver1")
        let t3Step = await play([u1, a1, u2, a2, u3, step, ChatMessage(role: .tool, content: "{}")])
        #expect(t3Step.calls.isEmpty)
    }

    /// Q-015 r5: `{{artifact}}` = the newest artifact_id a tool result in the prompt names.
    @Test func lastArtifactIsTheNewestNamedID() {
        let r = ChatRequest(modelSlot: .scripted("x"), messages: [
            ChatMessage(role: .user, content: "make it"),
            ChatMessage(role: .assistant, content: #"{"artifact_id":"a1","file":"x"} then {"artifact_id": "a2"}"#),
            ChatMessage(role: .user, content: "again"),
        ])
        #expect(EngineScriptPlayer.lastArtifact(r) == "a2")
        var withContext = r
        withContext.turnContext = #"Files made in this chat: "Budget.xlsx" artifact_id "f9" (version 1); "Old.md" artifact_id "f1" (version 2)."#
        #expect(EngineScriptPlayer.lastArtifact(withContext) == "f9", "the turn context's newest file first")
        #expect(EngineScriptPlayer.lastArtifact(ChatRequest(modelSlot: .scripted("x"), messages: [ChatMessage(role: .user, content: "q")])) == nil)
    }

    @Test func parseErrorsNameTheLine() {
        #expect(throws: EngineScript.ParseError.self) { try EngineScript(text: "{\"t\":\"textDelta\",\"v\":\"a\"}\n{\"t\":\"bogus\"}") }
        do {
            _ = try EngineScript(text: "# c\n{\"t\":\"textDelta\",\"v\":\"a\"}\n{\"t\":\"caps\"}")
            Issue.record("caps after content must fail")
        } catch let e as EngineScript.ParseError {
            #expect(e.line == 3)
        } catch { Issue.record("\(error)") }
    }

    @Test func longContextRepliesAreAbout600Tokens() async throws {
        let log = try await Self.run(ScriptedEngine(), Self.req(ScriptFixtures.url("long-context")))
        guard case .usage(let u)? = log.events.dropLast().last else { Issue.record("no usage"); return }
        #expect(u.completionTokens == 600)
    }
}
