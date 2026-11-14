// M8.T13 / AT-106 (R-106 AC1): the quick panel's Esc state machine, Return sends (a new chat on the first send, the
// same chat for a follow-up), Open in AntiChat hands the same chat id, Evil only when offered. And AT-105 (R-105
// AC1): the menu bar rows in order, with progress rows and the voice reason.
import AntiChatEngineProtocol
import AntiChatPlatform
import AppKit
import Foundation
import Testing

@testable import AntiChatUI

@MainActor
final class FakeQuickBackend: QuickPanelBackend {
    var sent: [(text: String, chatID: String?, mode: ComposerChatMode)] = []
    var opened: [String] = []
    var stopped: [String] = []
    var streaming = true
    var replyText = "4"
    var offersEvil = false
    var nextID = 0

    func send(_ text: String, chatID: String?, mode: ComposerChatMode) -> String? {
        sent.append((text, chatID, mode))
        if let chatID { return chatID }
        nextID += 1
        return "chat-\(nextID)"
    }

    func reply(chatID: String) -> (text: String, streaming: Bool) { (replyText, streaming) }
    func openInApp(chatID: String) { opened.append(chatID) }
    func stop(chatID: String) {
        stopped.append(chatID)
        streaming = false
    }
}

@MainActor @Suite(.isolatedSettings) struct QuickPanelViewModelTests {
    func make() -> (QuickPanelViewModel, FakeQuickBackend, () -> Int) {
        let b = FakeQuickBackend()
        let m = QuickPanelViewModel(backend: b)
        var hides = 0
        m.hide = { hides += 1 }
        return (m, b, { hides })
    }

    @Test func returnSendsAndTheReplyStreamsInThePanel() {
        let (m, b, _) = make()
        #expect(!m.send(), "empty: nothing sent")
        m.text = "What's 2+2?"
        #expect(m.send())
        #expect(b.sent.count == 1 && b.sent[0].chatID == nil && b.sent[0].text == "What's 2+2?")
        #expect(m.chatID == "chat-1" && m.text.isEmpty)
        #expect(m.phase == .streaming && m.showsReply && m.size.height == QuickPanelViewModel.minimumExpandedHeight)
        m.text = "and 3+3?"
        #expect(!m.send(), "no second send while the reply streams")
        b.streaming = false
        #expect(m.phase == .done)
        #expect(m.send())
        #expect(b.sent.last?.chatID == "chat-1", "a follow-up stays in the panel's chat")
    }

    /// vq/voice-mac-capture (S-22): stop while streaming stops the panel's chat; the question stays echoed above the reply.
    @Test func stopWhileStreamingStopsTheChatAndKeepsTheReply() {
        let (m, b, hides) = make()
        #expect(!m.stop(), "nothing streams yet")
        m.text = "Plan a weekend in Lisbon"
        m.send()
        #expect(m.prompt == "Plan a weekend in Lisbon")
        #expect(m.stop())
        #expect(b.stopped == ["chat-1"] && m.phase == .done && m.showsReply && hides() == 0)
        #expect(!m.stop(), "a finished reply has nothing to stop")
        m.escape()
        #expect(m.prompt.isEmpty && !m.showsReply)
    }

    @Test func escapeWhileStreamingHidesAndTheAnswerContinues() {
        let (m, b, hides) = make()
        m.text = "Long answer please"
        m.send()
        #expect(m.escape() == .hidePanel)
        #expect(hides() == 1)
        #expect(m.chatID == "chat-1" && m.phase == .streaming, "the chat keeps streaming in the background")
        m.shown()
        #expect(m.phase == .streaming && m.chatID == "chat-1", "re-opening shows the same reply")
        b.streaming = false
        #expect(m.phase == .done)
    }

    @Test func escapeCollapsesThenHides() {
        let (m, b, hides) = make()
        m.text = "Hi"
        m.send()
        b.streaming = false
        #expect(m.escape() == .collapsedReply)
        #expect(hides() == 0 && !m.showsReply && m.chatID == nil && m.size == QuickPanelViewModel.compactSize)
        #expect(m.escape() == .hidePanel)
        #expect(hides() == 1)
        #expect(m.escape() == .hidePanel, "empty panel: Esc hides")
    }

    @Test func openInAppHandsTheSameChat() {
        let (m, b, hides) = make()
        #expect(m.openInApp() == nil, "no chat yet")
        m.text = "Plan a trip"
        m.send()
        #expect(m.openInApp() == "chat-1")
        #expect(b.opened == ["chat-1"])
        #expect(hides() == 1 && m.chatID == nil)
    }

    @Test func evilOnlyWhenOffered() {
        let (m, b, _) = make()
        m.mode = .evil
        m.text = "x"
        m.send()
        #expect(b.sent.last?.mode == .normal, "Evil Mode off or hidden: Normal")
        b.streaming = false
        m.escape()
        b.offersEvil = true
        m.mode = .evil
        m.text = "y"
        m.send()
        #expect(b.sent.last?.mode == .evil && b.sent.last?.chatID == nil)
    }

    @Test func showingAgainAfterADoneReplyStartsFresh() {
        let (m, b, _) = make()
        m.text = "Hi"
        m.send()
        b.streaming = false
        let before = m.focusRequest
        m.shown()
        #expect(m.chatID == nil && !m.showsReply && m.focusRequest != before)
    }
}

@MainActor @Suite(.isolatedSettings) struct MenuBarModelTests {
    static let text: (String, [String: String]) -> String = { key, args in
        let t = ["mb.newChat": "New Chat", "mb.quickPanel": "Quick Panel", "mb.voice": "Start Voice", "mb.open": "Open AntiChat",
                 "mb.quit": "Quit AntiChat", "pill.download": "{pack} {percent}%", "pill.paused": "{pack} paused",
                 "onb.pack.photo.name": "Photo", "onb.pack.voice.name": "Voice", "add.disabled.pack": "Install {pack} to use this",
                 "mb.job.image": "Picture {percent}%", "mb.job.video": "Video {percent}%", "mb.job.videoEta": "Video · {time} left",
                 "voice.showChat": "Show chat", "voice.end": "End", "badge.evil": "Evil"]
        var s = t[key] ?? key
        for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    func titles(_ rows: [MenuBarItem]) -> [String] { rows.map { $0.isSeparator ? "—" : $0.title } }

    @Test func idleMenuInOrder() {
        let rows = MenuBarModel.items(downloads: [], jobs: [], voiceReady: true, quickPanelShortcut: "⌥Space", callActive: false,
                                      text: Self.text)
        #expect(titles(rows) == ["New Chat", "Quick Panel", "Start Voice", "—", "Open AntiChat", "Quit AntiChat"])
        #expect(rows[0].keyEquivalent == "n" && rows[0].modifiers == .command)
        #expect(rows[1].reason == "⌥Space", "the Quick Panel row shows its shortcut")
        #expect(rows.last?.keyEquivalent == "q" && rows.last?.action == .quit)
        #expect(rows.allSatisfy { $0.enabled })
    }

    @Test func voiceMissingIsDisabledWithItsReason() {
        let rows = MenuBarModel.items(downloads: [], jobs: [], voiceReady: false, quickPanelShortcut: nil, callActive: false, text: Self.text)
        let voice = rows.first { $0.id == "voice" }
        #expect(voice?.enabled == false && voice?.reason == "Install Voice to use this")
        #expect(rows.first { $0.id == "quickPanel" }?.reason == nil, "hotkey off: no shortcut shown")
    }

    @Test func progressRowsForDownloadsAndJobs() {
        let dl = PackProgress(pack: "photo", bytesDone: 42, bytesTotal: 100, bytesPerSecond: 1, etaSeconds: 10, state: .downloading, errorKey: nil)
        let jobs = [MenuBarModel.Job(id: "j1", kind: .video, chatID: "c1", progress: 0.3, etaSeconds: 80),
                    MenuBarModel.Job(id: "j2", kind: .image, chatID: "c2", progress: 0.5, etaSeconds: nil),
                    MenuBarModel.Job(id: "j3", kind: .video, chatID: "c3", progress: 0.25, etaSeconds: nil)]
        let rows = MenuBarModel.items(downloads: [dl], jobs: jobs, voiceReady: true, quickPanelShortcut: "⌥Space", callActive: false,
                                      text: Self.text)
        #expect(titles(rows) == ["New Chat", "Quick Panel", "Start Voice", "—", "Photo 42%", "Video · 1:20 left", "Picture 50%",
                                 "Video 25%", "—", "Open AntiChat", "Quit AntiChat"])
        #expect(rows.first { $0.id == "download.photo" }?.action == .openCapabilities)
        #expect(rows.first { $0.id == "job.j2" }?.action == .openChat("c2"))
        #expect(MenuBarModel.isBusy(downloads: [dl], jobs: []) && MenuBarModel.isBusy(downloads: [], jobs: jobs))
        #expect(!MenuBarModel.isBusy(downloads: [], jobs: []))
        let done = PackProgress(pack: "photo", bytesDone: 100, bytesTotal: 100, bytesPerSecond: 0, etaSeconds: nil, state: .done, errorKey: nil)
        #expect(!MenuBarModel.isBusy(downloads: [done], jobs: []))
        #expect(titles(MenuBarModel.items(downloads: [done], jobs: [], voiceReady: true, quickPanelShortcut: nil, callActive: false,
                                          text: Self.text)).count == 6, "a finished download leaves the menu")
    }

    @Test func callRowsComeFirstDuringACall() {
        let rows = MenuBarModel.items(downloads: [], jobs: [], voiceReady: true, quickPanelShortcut: nil, callActive: true, text: Self.text)
        #expect(Array(titles(rows).prefix(4)) == ["Show chat", "End", "—", "New Chat"])
    }

    @Test func clockFormat() {
        #expect(MenuBarModel.clock(80) == "1:20")
        #expect(MenuBarModel.clock(5) == "0:05")
        #expect(MenuBarModel.clock(3723) == "1:02:03")
    }
}
