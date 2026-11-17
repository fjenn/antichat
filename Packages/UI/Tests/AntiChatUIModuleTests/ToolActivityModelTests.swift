// M1.T16 AT-232 (4), UI half in-process (XCUITest J12ToolApprovalTests is blocked here, Q-015): the
// ConversationModel on the ScriptedEngine + scripted tools shows one activity line per call (running → done), the
// loop-limit notice at T1's 6 steps whose [Continue] resumes the same reply, and the ApprovalCard for write_note
// whose Allow once / Always allow / Deny answers behave as specified; a reloaded chat shows the same lines from the
// persisted `activity` parts. The views render (AssistantMessageView with activities, ApprovalCardView, LoopLimitNotice).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ToolActivityModelTests {
    static let runaway = """
        {"t":"toolCallDone","id":"call_{{n}}","name":"echo","args":"{\\"text\\":\\"step {{n}}\\"}","delayMs":1}
        """
    static let write = """
        {"t":"toolCallDone","id":"call_{{n}}","name":"write_note","args":"{\\"text\\":\\"note {{n}}\\"}","delayMs":1}
        {"t":"turn"}
        {"t":"textDelta","v":"Saved.","delayMs":1}
        """

    private func make(_ script: String) throws -> (ConversationModel, ChatEnvironment, ToolRegistry) {
        let db = try AppDatabase.inMemory()
        let registry = ToolRegistry([ScriptedTools.getTime(), ScriptedTools.echo(), ScriptedTools.writeNote()])
        let env = ChatEnvironment(
            database: db, engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
            tools: ToolRuntime(registry: registry, permissions: ToolPermissionStore(db), policy: .forTier(.t1), selection: .off),
            slot: { .scripted("inline") })
        return (ConversationModel(environment: env), env, registry)
    }

    private func wait(_ m: ConversationModel, until: () -> Bool) async {
        for _ in 0..<1000 where !until() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func waitIdle(_ m: ConversationModel) async {
        await wait(m) { !m.isGenerating && ![.pending, .streaming].contains(m.messages.last?.status) }
    }

    @Test func activityLinesLoopLimitAndContinue() async throws {
        let (m, env, registry) = try make(Self.runaway)
        m.send("go")
        await waitIdle(m)
        var reply = try #require(m.messages.last)
        #expect(reply.status == .done)
        #expect(reply.activities.filter { $0.kind == .tool }.count == 6)
        #expect(reply.activities.filter { $0.kind == .tool }.allSatisfy { $0.state == .done })
        #expect(reply.activities.last?.isLoopLimit == true)
        // The reply renders its lines and the notice.
        let view = AssistantMessageView(
            message: reply, status: m.statusModel(for: reply), onEditPrompt: {}, onRetry: {}, liveText: nil, live: nil,
            actions: ResponseActions(), copied: false, voiceInstalled: false, busy: false, isLast: true)
        let host = NSHostingView(rootView: view.frame(width: 600))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 6 * 16)
        // [Continue]: the same reply, a fresh budget of 6.
        m.continueTools(reply.id)
        await wait(m) { m.isGenerating }
        await waitIdle(m)
        reply = try #require(m.messages.last)
        #expect(m.messages.count == 2)
        #expect(registry.invocations(of: "echo") == 12)
        #expect(reply.activities.filter { $0.kind == .tool }.count == 12)
        #expect(reply.activities.last?.isLoopLimit == true)
        // Reload: the same lines from the persisted parts.
        let reloaded = ConversationModel(environment: env, chatID: m.chatID)
        #expect(reloaded.messages.last?.activities.filter { $0.kind == .tool }.count == 12)
    }

    @Test(arguments: [ApprovalAnswer.allowOnce, .always, .deny])
    func approvalCardPaths(_ answer: ApprovalAnswer) async throws {
        let (m, env, registry) = try make(Self.write)
        m.send("save a note")
        await wait(m) { m.messages.last?.approval != nil }
        let reply = try #require(m.messages.last)
        let card = try #require(reply.approval)
        #expect(card.tool == "write_note" && card.sideEffect == .write)
        #expect(reply.activities.first?.state == .awaitingApproval)
        let host = NSHostingView(rootView: ApprovalCardView(request: card, onAnswer: { _ in }).frame(width: 500))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 40)
        m.answerApproval(reply.id, card.id, answer)
        await waitIdle(m)
        let done = try #require(m.messages.last)
        #expect(done.approval == nil)
        // VQ-M10 S-24: after a Deny the reply never claims the call ran (the script's "Saved." step is not asked for).
        #expect(done.text == (answer == .deny ? PermissionGate.defaultDeniedReply : "Saved."))
        let stored = try ToolPermissionStore(env.database).policy(toolKey: "write_note", chatID: m.chatID)
        switch answer {
        case .allowOnce:
            #expect(registry.invocations(of: "write_note") == 1 && stored == nil)
            #expect(done.activities.first?.state == .done)
        case .always:
            #expect(registry.invocations(of: "write_note") == 1 && stored == .always)
            #expect(done.activities.first?.state == .done)
        case .deny:
            #expect(registry.invocations(of: "write_note") == 0 && stored == nil)
            #expect(done.activities.first?.state == .denied)
        }
    }

    /// VQ-M10 S-24: the card reads the arguments as labelled lines (recipient first, long text last); nested values stay in Details.
    @Test func approvalCardFieldsAreReadable() {
        let f = ApprovalCardView.fields(#"{"text":"Lunch is at noon.","channel":"general","meta":{"a":1},"to":["a@x.dev","b@x.dev"],"dryRun":false,"empty":""}"#)
        // Who it goes to first, long text last; the rest as the model wrote it.
        #expect(f.map(\.label) == ["Channel", "To", "Dry run", "Text"])
        #expect(f.map(\.value) == ["general", "a@x.dev, b@x.dev", "false", "Lunch is at noon."])
        #expect(ApprovalCardView.label("channel_id") == "Channel id" && ApprovalCardView.label("threadTs") == "Thread ts")
        #expect(ApprovalCardView.fields("not json").isEmpty && ApprovalCardView.fields("[1,2]").isEmpty)
        #expect(ApprovalCardView.prettyJSON(#"{"b":1,"a":"x"}"#).contains("\n"))
    }

    @Test func viewsBuild() {
        for state in [ToolActivity.State.running, .done, .failed, .denied, .skipped, .awaitingApproval] {
            let host = NSHostingView(rootView: ActivityLineView(activity: ToolActivity(id: "1", tool: "echo", state: state)))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height > 0)
        }
        let notice = NSHostingView(rootView: LoopLimitNotice(onContinue: {}))
        notice.layoutSubtreeIfNeeded()
        #expect(notice.fittingSize.width > 0)
    }

    /// M9.T08: activity lines name the tool for people ("Web search didn't work. Retry"), never by its id.
    @Test func activityLinesUseAReadableToolName() {
        #expect(ActivityLineView.readableName("web_search") == "Web search")
        #expect(ActivityLineView.readableName("echo") == "Echo")
    }
}
