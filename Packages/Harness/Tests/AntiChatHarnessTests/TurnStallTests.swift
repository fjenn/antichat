// M7 bars-2 (S1, lead decision 2026-11-10): "T3 answers that never come back" (held-out-3 h082, h084, h087).
// Root cause (trace `build/at/AT-250/bars2/hang/h082-before.json.stderr.log`): after the forced web step the T3 model
// calls `read_url` on one of the turn's own result pages; the turn is untrusted after `web_search`, so the call asked
// first (M7.T16 review #5) and the reply waited on an ApprovalCard that the headless bench never answered. Fix: a URL
// that is exactly a result of the turn's own search does not ask (UntrustedContextRule). Second leg: a request whose
// engine stream goes silent ends as `engine.stalled` (ErrorInline + Retry) instead of waiting forever.
//   make test-unit FILTER=TurnStallTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation
import Testing
@testable import AntiChatHarness

@Suite(.serialized) struct TurnStallTests {
    /// The h082 search: the result list the T3 run saw (jenkins.io pages from the replayed SERP), page 1 fetched.
    static let h082Results = ["https://www.jenkins.io/changelog-stable/", "https://www.jenkins.io/changelog/",
                              "https://www.jenkins.io/download/lts/", "https://www.jenkins.io/changelog-stable/rss.xml",
                              "https://www.jenkins.io/changelog-preview/", "https://www.jenkins.io/changelog-stable-old/"]

    static func search() -> RegisteredTool {
        RegisteredTool(name: "web_search", description: "Search the web.", parametersJSON: WebSearchTools.webSearchParameters,
                       sideEffect: .read, availability: .available, outputIsUntrusted: true) { _ in
            let srcs = h082Results.enumerated().map { i, u in
                WebSource(n: i + 1, url: u, title: "Jenkins \(i + 1)", site: "jenkins.io", date: nil, snippet: "LTS", fetched: i == 0)
            }
            let r = WebResults(queries: ["Jenkins LTS changelog"], sources: srcs,
                               evidence: [EvidenceChunk(source: 1, url: URL(string: srcs[0].url)!, site: "jenkins.io", title: "Jenkins 1",
                                                        text: "What's new in 2.528.1 (2025-10-08)", ordinal: 0)],
                               evidenceTokens: 9, failed: nil)
            return WebResultsBlock.render(TurnWebSources.shared.record(r, turn: TurnContext.requestID ?? "-"))
        }
    }

    static func readURL() -> RegisteredTool {
        RegisteredTool(name: "read_url", description: "Read a web page.", parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}"#,
                       sideEffect: .read, availability: .available, outputIsUntrusted: true) { _ in
            "<web_results untrusted=\"true\">[1] 2.528.1: fixes and dependency updates.</web_results>"
        }
    }

    /// The h082 T3 run's calls, replayed: the forced web_search, then read_url on `url`, then the answer.
    static func script(_ url: String) -> String {
        """
        {"t":"toolCallDone","id":"call_0","name":"web_search","args":"{\\"queries\\":[\\"Jenkins latest LTS release changelog 2026\\",\\"Jenkins LTS release notes latest version\\"],\\"category\\":\\"news\\",\\"freshness\\":\\"month\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"toolCallDone","id":"call_1","name":"read_url","args":"{\\"url\\":\\"\(url)\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Jenkins 2.528.1 is the latest LTS [1].","delayMs":1}
        """
    }

    func approvals(_ log: UpdateLog, _ id: String) -> [ToolApprovalRequest] {
        log.all.compactMap { u in if u.assistantID == id, case .approval(let r?) = u.kind { r } else { nil } }
    }

    /// Regression (h082 replay): reading a page of the turn's own results runs without a card and the reply arrives.
    @Test func h082ReadingAResultPageNeedsNoApprovalAndTheReplyArrives() async throws {
        let h = try ToolLoopHarness(script: Self.script("https://www.jenkins.io/changelog-stable/"), tier: .t3,
                                    tools: [Self.search(), Self.readURL()], selection: .standard)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What changed in the latest Jenkins LTS release?")
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .done && r.text.contains("2.528.1"), "\(r.status) \(r.text)")
        #expect(approvals(h.log, a).isEmpty)
        let acts = try h.activities(a)
        #expect(acts.contains { $0.tool == "read_url" && $0.state == .done }, "\(acts.map { ($0.tool, $0.state) })")
    }

    /// A URL that is not one of the results (here: the result plus a query string) still asks first.
    @Test func aURLOutsideTheResultsStillAsks() async throws {
        let h = try ToolLoopHarness(script: Self.script("https://www.jenkins.io/changelog-stable/?d=chat"), tier: .t3,
                                    tools: [Self.search(), Self.readURL()], selection: .standard)
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What changed in the latest Jenkins LTS release?")
        try await h.log.wait(.seconds(30)) { _ in h.pendingApproval(a) != nil }
        let card = try #require(h.pendingApproval(a))
        #expect(card.tool == "read_url" && card.untrusted)
        await h.controller.answerApproval(callID: card.id, .deny)
        let r = try await h.log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .done)
    }

    static func controller(_ script: String, stall: Duration) throws -> (TurnController, UpdateLog) {
        let c = TurnController(chatID: StorageID.make(), database: try AppDatabase.inMemory(),
                               engine: try InProcessScriptedEngine(script: EngineScript(text: script)), stallLimit: stall) { .scripted("inline") }
        return (c, UpdateLog(c))
    }

    /// A stream that goes silent after some text: the reply ends interrupted with `engine.stalled` (notice + Retry).
    @Test func silentStreamEndsAsStalledWithRetry() async throws {
        let (c, log) = try Self.controller("""
            {"t":"textDelta","v":"Partial answer","delayMs":1}
            {"t":"wait","ms":60000}
            {"t":"textDelta","v":" never","delayMs":1}
            """, stall: .milliseconds(400))
        let a = StorageID.make()
        let t = ContinuousClock.now
        await c.start(.send(userID: StorageID.make(), text: "hi", parentID: nil), assistantID: a)
        let r = try await log.waitFinished(a, timeout: .seconds(20))
        #expect(ContinuousClock.now - t < .seconds(15))
        #expect(r.status == .interrupted && r.errorCode == "engine.stalled" && r.text == "Partial answer", "\(r.status) \(String(describing: r.errorCode))")
        #expect(AntiChatError.Code.engineStalled.defaultRecovery == [.retry])
    }

    /// Silence during prefill (nothing streamed yet): the reply fails with `engine.stalled` (ErrorInline + Retry).
    @Test func silentPrefillFailsAsStalled() async throws {
        let (c, log) = try Self.controller("""
            {"t":"prefill","ms":20,"steps":1}
            {"t":"wait","ms":60000}
            {"t":"textDelta","v":"late","delayMs":1}
            """, stall: .milliseconds(400))
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "hi", parentID: nil), assistantID: a)
        let r = try await log.waitFinished(a, timeout: .seconds(20))
        #expect(r.status == .error && r.errorCode == "engine.stalled", "\(r.status) \(String(describing: r.errorCode))")
    }

    /// R2 review P1-2: a long prefill that reports progress (llama-server `return_progress`, the MLX prefix and prompt
    /// prefill) is not silence, however long it runs in total: here 2.4 s of prefill (6 × the stall limit) in
    /// 120 ms steps after a model load, then the answer.
    @Test func aLongPrefillThatReportsProgressIsNotAStall() async throws {
        let (c, log) = try Self.controller("""
            {"t":"load","ms":20,"steps":1}
            {"t":"prefill","ms":2400,"steps":20}
            {"t":"textDelta","v":"Read it all.","delayMs":1}
            """, stall: .milliseconds(400))
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "Summarise this long document", parentID: nil), assistantID: a)
        let r = try await log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .done && r.errorCode == nil && r.text == "Read it all.", "\(r.status) \(String(describing: r.errorCode))")
    }

    /// AT-273 round 65 (T05 csv-06 & co.): MLX writes a long create_document / create_spreadsheet call without any
    /// visible delta (the call is handed over complete); the adapter's `generating` pulses are liveness, so a call
    /// written for 2.4 s (6 × the stall limit) with tokens flowing is not a stall, and the file call then runs.
    @Test func aLongToolCallThatReportsGeneratingIsNotAStall() async throws {
        let (c, log) = try Self.controller("""
            {"t":"generating","ms":2400,"steps":24}
            {"t":"textDelta","v":"Here it is.","delayMs":1}
            """, stall: .milliseconds(400))
        let a = StorageID.make()
        await c.start(.send(userID: StorageID.make(), text: "Make me a CSV of 500 items", parentID: nil), assistantID: a)
        let r = try await log.waitFinished(a, timeout: .seconds(30))
        #expect(r.status == .done && r.errorCode == nil && r.text == "Here it is.", "\(r.status) \(String(describing: r.errorCode))")
    }

    /// AT-273 round 65: generation that stops (pulses, then nothing) is still caught: no stall limit was raised.
    @Test func silenceAfterGeneratingPulsesIsStillAStall() async throws {
        let (c, log) = try Self.controller("""
            {"t":"generating","ms":600,"steps":6}
            {"t":"wait","ms":60000}
            {"t":"textDelta","v":"late","delayMs":1}
            """, stall: .milliseconds(400))
        let a = StorageID.make()
        let t = ContinuousClock.now
        await c.start(.send(userID: StorageID.make(), text: "hi", parentID: nil), assistantID: a)
        let r = try await log.waitFinished(a, timeout: .seconds(20))
        #expect(ContinuousClock.now - t < .seconds(15))
        #expect(r.errorCode == "engine.stalled", "\(r.status) \(String(describing: r.errorCode))")
    }

    /// R2 review P1-2: the watchdog still catches a real stall in the middle of a prefill (progress, then silence).
    @Test func silenceInTheMiddleOfAPrefillIsStillAStall() async throws {
        let (c, log) = try Self.controller("""
            {"t":"load","ms":20,"steps":1}
            {"t":"prefill","ms":600,"steps":5}
            {"t":"wait","ms":60000}
            {"t":"textDelta","v":"late","delayMs":1}
            """, stall: .milliseconds(400))
        let a = StorageID.make()
        let t = ContinuousClock.now
        await c.start(.send(userID: StorageID.make(), text: "hi", parentID: nil), assistantID: a)
        let r = try await log.waitFinished(a, timeout: .seconds(20))
        #expect(ContinuousClock.now - t < .seconds(15))
        #expect(r.status == .error && r.errorCode == "engine.stalled", "\(r.status) \(String(describing: r.errorCode))")
    }

    /// An ApprovalCard waiting for the user is not a stall: the turn keeps waiting for the answer.
    @Test func aPendingApprovalIsNotAStall() async throws {
        let h = try ToolLoopHarness(script: Self.script("https://evil.test/x"), tier: .t3,
                                    tools: [Self.search(), Self.readURL()], selection: .standard, stallLimit: .milliseconds(300))
        await h.controller.setChips(["web"])
        let (_, a) = await h.send("What changed in the latest Jenkins LTS release?")
        try await h.log.wait(.seconds(30)) { _ in h.pendingApproval(a) != nil }
        try await Task.sleep(for: .seconds(2))  // > 6 × the stall limit
        #expect(h.log.finished(a) == nil, "still waiting for the user")
        await h.controller.answerApproval(callID: try #require(h.pendingApproval(a)).id, .allowOnce)
        #expect(try await h.log.waitFinished(a, timeout: .seconds(30)).status == .done)
    }
}
