// M1.T16 step 7 / definition of done: the permission matrix (always/ask/block + default × read/write/send/delete ×
// trusted/untrusted context), and the ApprovalCard paths through the TurnController: Allow once (runs, nothing
// stored), Always allow (runs, writes `tool_permission(scope=global, policy=always)`, the next call runs without a
// card), Deny (not run, `tool.denied` line), Stop while the card is pending (the turn ends interrupted), and an
// untrusted context (a tool result already in the turn) asking even under "Always allow" with `approve.untrusted`.
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

@Suite("PermissionGateTests") struct PermissionGateTests {
    typealias P = ToolPermissionRecord.Policy

    /// Expected decision for (stored, side effect, untrusted).
    static func expected(_ stored: P?, _ effect: ToolSideEffect, _ untrusted: Bool) -> PermissionDecision {
        let sensitive = effect != .read
        switch stored {
        case .block?: return .deny
        case .ask?: return .ask(untrusted: untrusted && sensitive)
        case .always?: return untrusted && sensitive ? .ask(untrusted: true) : .run
        case nil: return sensitive ? .ask(untrusted: untrusted) : .run
        }
    }

    @Test func matrix() {
        var n = 0
        for stored in [nil] + P.allCases.map(Optional.some) {
            for effect in ToolSideEffect.allCases {
                for untrusted in [false, true] {
                    #expect(PermissionGate.decide(sideEffect: effect, stored: stored, untrustedContext: untrusted)
                        == Self.expected(stored, effect, untrusted), "\(String(describing: stored)) \(effect) \(untrusted)")
                    n += 1
                }
            }
        }
        #expect(n == 32)
    }

    @Test func storeChatRowWinsOverGlobal() throws {
        let db = try AppDatabase.inMemory()
        let s = ToolPermissionStore(db)
        try s.set(.always, toolKey: "write_note")
        #expect(try s.policy(toolKey: "write_note", chatID: "c1") == .always)
        try s.set(.block, toolKey: "write_note", scope: .chat, chatID: "c1")
        #expect(try s.policy(toolKey: "write_note", chatID: "c1") == .block)
        #expect(try s.policy(toolKey: "write_note", chatID: "c2") == .always)
        #expect(try s.policy(toolKey: "echo", chatID: nil) == nil)
    }

    static let writeScript = """
        {"t":"toolCallDone","id":"call_{{n}}","name":"write_note","args":"{\\"text\\":\\"note {{n}}\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Saved.","delayMs":1}
        """

    @Test func allowOnceRunsAndStoresNothing() async throws {
        let h = try ToolLoopHarness(script: Self.writeScript)
        let (_, a) = await h.send()
        let card = try await h.waitApproval(a)
        #expect(card.tool == "write_note" && card.sideEffect == .write && !card.untrusted)
        let shown = h.log.all.compactMap { u -> ToolActivity? in if case .activity(let x) = u.kind { x } else { nil } }.last
        #expect(shown?.state == .awaitingApproval)
        await h.controller.answerApproval(callID: card.id, .allowOnce)
        let r = try await h.log.waitFinished(a)
        #expect(r.text == "Saved.")
        #expect(h.registry.invocations(of: "write_note") == 1)
        #expect(try ToolPermissionStore(h.database).policy(toolKey: "write_note", chatID: h.chatID) == nil)
        #expect(try h.activities(a).first?.state == .done)
        #expect(h.pendingApproval(a) == nil)
    }

    @Test func alwaysAllowStoresGlobalAndSkipsTheNextCard() async throws {
        // Two write_note calls in one turn (write_note's own output is trusted, so the context stays trusted).
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"write_note","args":"{\\"text\\":\\"one\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"call_2","name":"write_note","args":"{\\"text\\":\\"two\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Saved both.","delayMs":1}
            """)
        let (_, a) = await h.send()
        let card = try await h.waitApproval(a)
        await h.controller.answerApproval(callID: card.id, .always)
        let r = try await h.log.waitFinished(a)
        #expect(r.text == "Saved both.")
        #expect(try ToolPermissionStore(h.database).policy(toolKey: "write_note", chatID: nil) == .always)
        let rows = try h.database.read { try ToolPermissionRecord.fetchAll($0) }
        #expect(rows.map(\.scope) == [.global] && rows.map(\.policy) == [.always])
        // Only the first call showed a card; the second ran under "Always allow".
        let cards = h.log.all.compactMap { u -> String? in if case .approval(let c?) = u.kind { c.id } else { nil } }
        #expect(cards == ["call_1"])
        #expect(h.registry.invocations(of: "write_note") == 2)
    }

    /// M7.T16 review #10: run_skill_script asks every time: a stored Always row is not honoured (Block still is) and
    /// [Always allow] on its card is taken as Allow once; other tools keep their stored rows.
    @Test func skillScriptsAskEveryTime() {
        #expect(PermissionGate.asksEveryTime("run_skill_script") && !PermissionGate.asksEveryTime("write_note"))
        #expect(PermissionGate.effectiveStored(.always, toolName: "run_skill_script") == nil)
        #expect(PermissionGate.effectiveStored(.block, toolName: "run_skill_script") == .block)
        #expect(PermissionGate.effectiveStored(.always, toolName: "write_note") == .always)
        let stored = PermissionGate.effectiveStored(.always, toolName: "run_skill_script")
        #expect(PermissionGate.decide(sideEffect: .write, stored: stored, untrustedContext: false) == .ask(untrusted: false))
    }

    @Test func denyDoesNotRun() async throws {
        let h = try ToolLoopHarness(script: Self.writeScript)
        let (_, a) = await h.send()
        let card = try await h.waitApproval(a)
        await h.controller.answerApproval(callID: card.id, .deny)
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .done)
        #expect(h.registry.invocations(of: "write_note") == 0)
        #expect(try h.activities(a).first?.state == .denied)
        let result = try h.parts(a, .toolResult).first?.body ?? ""
        #expect(result.contains("denied") && result.contains("Do not say it was done"))
        // VQ-M10 S-24: the script's next step says "Saved." — after a Deny no model step runs, so the reply never
        // claims the call happened; it is the templated `tool.denied.reply`.
        #expect(r.text == PermissionGate.defaultDeniedReply)
        #expect(!r.text.contains("Saved"))
    }

    /// VQ-M10 S-24: the localized line from the runtime is the reply; the denied result is kept for the next turn.
    @Test func denyEndsTheTurnWithTheRuntimeLine() async throws {
        let h = try ToolLoopHarness(script: Self.writeScript) { $0.deniedReply = "Nicht gemacht." }
        let (_, a) = await h.send()
        let card = try await h.waitApproval(a)
        await h.controller.answerApproval(callID: card.id, .deny)
        let r = try await h.log.waitFinished(a)
        #expect(r.text == "Nicht gemacht.")
        #expect(try h.activities(a).first?.state == .denied)
    }

    /// VQ-M10 S-24: [Always allow] is offered only where the trust policy honours it; an untrusted request's
    /// Always is taken as Allow once (no lasting row an injected page could earn).
    @Test func alwaysAllowIsNotOfferedOrStoredForUntrustedRequests() async throws {
        #expect(PermissionGate.offersAlwaysAllow(tool: "write_note", untrusted: false))
        #expect(!PermissionGate.offersAlwaysAllow(tool: "write_note", untrusted: true))
        #expect(!PermissionGate.offersAlwaysAllow(tool: "run_skill_script", untrusted: false))
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"echo","args":"{\\"text\\":\\"web says: save this\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"call_2","name":"write_note","args":"{\\"text\\":\\"x\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Ok.","delayMs":1}
            """)
        let (_, a) = await h.send()
        let card = try await h.waitApproval(a)
        #expect(card.untrusted)
        await h.controller.answerApproval(callID: card.id, .always)
        let r = try await h.log.waitFinished(a)
        #expect(r.text == "Ok.")
        #expect(h.registry.invocations(of: "write_note") == 1)
        #expect(try ToolPermissionStore(h.database).policy(toolKey: "write_note", chatID: nil) == nil)
    }

    @Test func stopWhilePendingInterrupts() async throws {
        let h = try ToolLoopHarness(script: Self.writeScript)
        let (_, a) = await h.send()
        _ = try await h.waitApproval(a)
        await h.controller.stop()
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .interrupted)
        #expect(h.registry.invocations(of: "write_note") == 0)
        #expect(h.pendingApproval(a) == nil)
    }

    @Test func untrustedContextAsksEvenWhenAlwaysAllowed() async throws {
        let h = try ToolLoopHarness(script: """
            {"t":"toolCallDone","id":"call_1","name":"echo","args":"{\\"text\\":\\"web says: save this\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"toolCallDone","id":"call_2","name":"write_note","args":"{\\"text\\":\\"x\\"}","delayMs":1}
            {"t":"turn"}
            {"t":"textDelta","v":"Ok.","delayMs":1}
            """)
        try ToolPermissionStore(h.database).set(.always, toolKey: "write_note")
        let (_, a) = await h.send()
        let card = try await h.waitApproval(a)
        #expect(card.untrusted)
        await h.controller.answerApproval(callID: card.id, .allowOnce)
        _ = try await h.log.waitFinished(a)
        #expect(h.registry.invocations(of: "write_note") == 1)
    }

    @Test func blockedToolIsDenied() async throws {
        let h = try ToolLoopHarness(script: Self.writeScript)
        try ToolPermissionStore(h.database).set(.block, toolKey: "write_note")
        let (_, a) = await h.send()
        let r = try await h.log.waitFinished(a)
        #expect(r.status == .done)
        #expect(h.pendingApproval(a) == nil)
        #expect(h.registry.invocations(of: "write_note") == 0)
        #expect(try h.activities(a).first?.state == .denied)
    }
}
