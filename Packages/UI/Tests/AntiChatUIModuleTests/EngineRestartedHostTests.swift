// AT-208 J13-UI legs, in-process form (M1.T12 × W2 integration; A-M1-T12c). XCUITest cannot run on this Mac
// (Q-015/Q-023/Q-024), so the helper-crash cases of `J13CrashRecoveryTests` are proven here on the wired window
// stack (ChatSessions → ConversationModel → TurnController → ConversationView) with the engine reporting
// `engine.restarted` mid-stream, exactly what `EngineSupervisorClient` yields when the helper dies (the real
// helper kill → `engine.restarted` + app survival is `HelperRestartTests`, AT-NFR-S4):
//   1. the partial reply is kept (UI = database) and the turn ends `interrupted` with `engine.restarted`;
//   2. ConversationView hosts EngineRestartedNotice (`engineRestartedNotice` > `interruptedNotice`, reason
//      "The AI engine restarted.", [Edit prompt], [Retry]) — read from the live window via the probe anchors;
//   3. a real click on [Retry] regenerates a sibling version (‹ 2/2 ›) once the engine is back;
//   4. a database left `streaming` by a crash is swept by `LaunchRecovery` when ChatEnvironment opens it.
// It also renders the S-25 engine-restarted capture for vq-02 step 10 (`build/at/AT-208/vq-02-step10/`).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import AntiChatUI

/// Plays the crash script on the first turn, the healthy script afterwards (helper restarted).
private final class RestartingEngine: EngineService {
    let crashing: InProcessScriptedEngine
    let healthy: InProcessScriptedEngine
    let calls = Mutex(0)

    init(crash: String, then healthy: String) throws {
        crashing = InProcessScriptedEngine(script: try EngineScript(text: crash))
        self.healthy = InProcessScriptedEngine(script: try EngineScript(text: healthy))
    }

    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        let n = calls.withLock { n in n += 1; return n }
        return (n == 1 ? crashing : healthy).chat(request, onLifecycle: onLifecycle)
    }
    func cancel(_ requestID: UUID) {
        crashing.cancel(requestID)
        healthy.cancel(requestID)
    }
    func capabilities() async -> EngineCapabilities? { await healthy.capabilities() }
}

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct EngineRestartedHostTests {
    static let crash = """
        {"t":"textDelta","v":"The harbour town","delayMs":5}
        {"t":"textDelta","v":" sits on a cove","delayMs":5}
        {"t":"crash"}
        """
    static let healthy = #"{"t":"textDelta","v":"A full answer after the restart.","delayMs":2}"#

    private func make() throws -> (WindowState, ChatSessions, ChatEnvironment) {
        let env = ChatEnvironment(database: try AppDatabase.inMemory(),
                                  engine: try RestartingEngine(crash: Self.crash, then: Self.healthy),
                                  slot: { .scripted("inline") })
        return (WindowState(service: ChatListService(environment: env), seed: 1), ChatSessions(environment: env), env)
    }

    private func waitIdle(_ m: ConversationModel) async {
        for _ in 0..<500 where m.isGenerating || [.pending, .streaming].contains(m.messages.last?.status) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func crashedChat() async throws -> (ChatSessions, ChatEnvironment, ConversationModel) {
        let (state, sessions, env) = try make()
        state.send("Tell me about the harbour town.", reduceMotion: true, turn: sessions.slots.startTurn)
        let model = sessions.model(for: try #require(state.currentChatID))
        await waitIdle(model)
        return (sessions, env, model)
    }

    private func host(_ model: ConversationModel, size: CGSize = CGSize(width: 760, height: 520)) -> NSWindow {
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.titled],
                           backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: ConversationView(model: model)
            .environment(\.reduceMotionOverride, true).frame(width: size.width, height: size.height))
        BackgroundRun.present(win)
        return win
    }

    private func settle(_ win: NSWindow, until cond: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            win.contentView?.layoutSubtreeIfNeeded()
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func click(_ win: NSWindow, _ id: String) -> Bool {
        guard let f = UIProbeRegistry.frame(id, in: win) else { return false }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: f.midX, y: f.midY), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: win.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1) else { return false }
            win.sendEvent(e)
        }
        return true
    }

    @Test func helperCrashMidStreamKeepsPartialAndMarksInterrupted() async throws {
        let (_, env, model) = try await crashedChat()
        let reply = try #require(model.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.status == .interrupted)
        #expect(reply.errorCode == "engine.restarted")
        #expect(reply.text == "The harbour town sits on a cove")
        let row = try #require(try MessageRepository(env.database).message(reply.id))
        #expect(row.status == .interrupted)
        #expect(try MessageRepository(env.database).parts(of: reply.id).first?.body == reply.text, "UI = database")
        #expect(!model.isGenerating, "the app stays usable (composer idle)")
        evidence("J13-UI-crash-mid-stream", ["status": "interrupted", "errorCode": reply.errorCode ?? "",
                                              "partialChars": reply.text.count])
    }

    @Test func conversationViewHostsEngineRestartedNoticeAndRetryRegenerates() async throws {
        let (_, _, model) = try await crashedChat()
        let win = host(model)
        defer { win.close() }
        let shown = await settle(win) { UIProbeRegistry.frame("engineRestartedNotice", in: win) != nil }
        #expect(shown, "EngineRestartedNotice not hosted for an engine.restarted turn")
        for id in ["interruptedNotice", "interruptedReason", "interruptedEdit", "interruptedRetry"] {
            #expect(UIProbeRegistry.frame(id, in: win) != nil, "missing \(id)")
        }
        // A real click on [Retry]: a sibling version streams from the restarted engine.
        #expect(click(win, "interruptedRetry"))
        try? await Task.sleep(for: .milliseconds(50))
        await waitIdle(model)
        let reply = try #require(model.messages.last)
        #expect(reply.status == .done)
        #expect(reply.text == "A full answer after the restart.")
        #expect(reply.version == 2 && reply.versionCount == 2, "‹ 2/2 › expected, got \(reply.version)/\(reply.versionCount)")
        let gone = await settle(win) { UIProbeRegistry.frame("engineRestartedNotice", in: win) == nil }
        #expect(gone, "notice should leave once the retried reply is done")
        evidence("J13-UI-retry", ["noticeHosted": shown, "retryVersion": "\(reply.version)/\(reply.versionCount)"])
    }

    @Test func plainInterruptionKeepsTheT06Notice() async throws {
        let env = ChatEnvironment(
            database: try AppDatabase.inMemory(),
            engine: InProcessScriptedEngine(script: try EngineScript(text: #"{"t":"textDelta","v":"slow","delayMs":400}"#)),
            slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        state.send("hi", reduceMotion: true, turn: sessions.slots.startTurn)
        let model = sessions.model(for: try #require(state.currentChatID))
        try? await Task.sleep(for: .milliseconds(100))
        model.stop()
        await waitIdle(model)
        let win = host(model)
        defer { win.close() }
        #expect(await settle(win) { UIProbeRegistry.frame("interruptedNotice", in: win) != nil })
        #expect(UIProbeRegistry.frame("engineRestartedNotice", in: win) == nil)
    }

    @Test func launchRecoverySweepsOnEnvironmentOpen() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-w2-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let options = LaunchOptions.parse(["-ANTICHAT_DEV_CONTAINER", container.path])
        let replyID: String
        do {
            let db = try AppDatabase.openDefault(options: options)
            let chat = try ChatRepository(db).create(title: "crash")
            let tree = MessageTree(db)
            let user = try tree.append(chatID: chat.id, parentID: nil, role: .user, parts: [PartContent(kind: .text, body: "hi")])
            replyID = try tree.append(chatID: chat.id, parentID: user.id, role: .assistant, status: .streaming,
                                      parts: [PartContent(kind: .text, body: "Partial")]).id
            try db.write { d in
                try MediaJobRecord(chatID: chat.id, kind: "image", specJSON: "{}", state: .running, progress: 0.2,
                                   startedAt: Date()).insert(d)
            }
        }
        let env = try ChatEnvironment.open(options: options, slot: { .scripted("inline") })
        #expect(env.sweptMessageIDs == [replyID])
        #expect(env.recovery.lostJobs.count == 1, "LaunchRecovery (not only the message sweep) ran at open")
        #expect(try MessageRepository(env.database).message(replyID)?.status == .interrupted)
    }

    /// vq-02 step 10 (S-25 engine-restarted state): the conversation column after a helper crash, light + dark.
    @Test func vq02Step10Capture() async throws {
        let (_, _, model) = try await crashedChat()
        let out = Self.atDir.appendingPathComponent("vq-02-step10", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for look in Look.allCases {
            let image = render(ConversationView(model: model), look: look, size: CGSize(width: 760, height: 420))
            let rep = try #require(image.representations.first as? NSBitmapImageRep)
            try #require(rep.representation(using: .png, properties: [:]))
                .write(to: out.appendingPathComponent("S-25-engine-restarted-\(look.rawValue).png"))
        }
    }

    // MARK: Evidence

    static var atDir: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("build/at/AT-208", isDirectory: true)
    }

    private func evidence(_ name: String, _ fields: [String: Any]) {
        try? FileManager.default.createDirectory(at: Self.atDir, withIntermediateDirectories: true)
        var f = fields
        f["case"] = name
        f["form"] = "in-process (AntiChatUIModuleTests/EngineRestartedHostTests); XCUITest leg pending Q-015/Q-023/Q-024"
        if let data = try? JSONSerialization.data(withJSONObject: f, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.atDir.appendingPathComponent("AT-208-\(name).json"))
        }
    }
}
}  // extension WindowSuites
