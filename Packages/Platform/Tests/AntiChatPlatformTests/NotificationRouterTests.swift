// M8.T12 / AT-108, AT-042 AC2: userInfo → navigation intent; a click before the windows exist is held; the content
// rules (incognito never names the chat, Evil says so in text, threadIdentifier = chat, sound per Settings).
import Foundation
import Testing

@testable import AntiChatPlatform

@MainActor @Suite struct NotificationRouterTests {
    static let text: NotificationContent.Text = { key, args in
        let table = ["notif.answer": "{chatTitle}: reply ready", "notif.answer.incognito": "Incognito chat: reply ready",
                     "notif.image": "Your picture is ready", "notif.image.failed": "Your picture didn't finish.",
                     "notif.video": "Your video is ready", "notif.video.failed": "Your video didn't finish.",
                     "notif.download": "{pack} is ready", "notif.update": "AntiChat {version} is ready — restart to update",
                     "side.untitled": "New chat", "title.incognito": "Incognito"]
        var s = table[key] ?? key
        for (k, v) in args { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }

    @Test func userInfoBecomesTheChatAndMessage() {
        let route = NotificationRoute(chatID: "c1", messageID: "m9", category: .video)
        #expect(route.userInfo == ["chatID": "c1", "messageID": "m9", "category": "video"])
        let back = NotificationRoute(userInfo: route.userInfo as [AnyHashable: Any])
        #expect(back == route)
        #expect(NotificationRouter.destination(for: route) == .chat(id: "c1", messageID: "m9"))
        #expect(NotificationRouter.destination(for: NotificationRoute(chatID: nil, messageID: nil, category: .download)) == .capabilities)
        #expect(NotificationRouter.destination(for: NotificationRoute(chatID: nil, messageID: nil, category: .update)) == .updates)
        #expect(NotificationRoute(userInfo: ["chatID": ""]) == nil)
        #expect(NotificationRoute(userInfo: [:]) == nil)
        #expect(NotificationRoute(userInfo: ["chatID": 7]) == nil, "only strings are read")
    }

    @Test func aClickBeforeTheWindowsExistIsHeld() {
        let r = NotificationRouter()
        r.open(userInfo: ["chatID": "c1", "messageID": "m1", "category": "answer"])
        r.open(userInfo: ["junk": "x"])
        var got: [NotificationDestination] = []
        r.handler = { got.append($0) }
        #expect(got == [.chat(id: "c1", messageID: "m1"), .app])
        r.open(userInfo: ["chatID": "c2"])
        #expect(got.last == .chat(id: "c2", messageID: nil))
        #expect(r.routed.count == 3)
    }

    @Test func answerContent() {
        let e = NotificationEvent(kind: .answer, chatID: "c1", messageID: "m1", chatTitle: "Trip plan")
        let s = NotificationContent.make(e, sound: .named("Glass"), id: "x", text: Self.text)
        #expect(s.category == .answer && s.title == "Trip plan" && s.body == "Trip plan: reply ready")
        #expect(s.threadID == "c1" && s.userInfo["chatID"] == "c1" && s.userInfo["messageID"] == "m1")
        #expect(s.sound == "Glass.aiff")
        let untitled = NotificationContent.make(NotificationEvent(kind: .answer, chatID: "c1"), sound: .systemDefault, text: Self.text)
        #expect(untitled.title == "New chat" && untitled.sound == "default")
        #expect(NotificationContent.make(e, sound: .none, text: Self.text).sound == nil)
    }

    @Test func incognitoNeverNamesTheChat() {
        let e = NotificationEvent(kind: .answer, chatID: "c1", messageID: "m1", chatTitle: "Secret", incognito: true)
        let s = NotificationContent.make(e, sound: .systemDefault, text: Self.text)
        #expect(!s.title.contains("Secret") && !s.body.contains("Secret"))
        #expect(s.body == "Incognito chat: reply ready")
        #expect(s.userInfo == ["category": "answer"] && s.threadID == nil, "no chat id leaves an incognito chat")
        #expect(NotificationRoute(userInfo: s.userInfo as [AnyHashable: Any]).map(NotificationRouter.destination(for:)) == .app)
        let img = NotificationContent.make(NotificationEvent(kind: .image(failed: false), chatID: "c1", chatTitle: "Secret", incognito: true),
                                           sound: .systemDefault, text: Self.text)
        #expect(!img.title.contains("Secret"))
    }

    @Test func evilTitleSaysSoInText() {
        let s = NotificationContent.make(NotificationEvent(kind: .video(failed: false), chatID: "c", messageID: "m", chatTitle: "Night", evil: true),
                                         sound: .systemDefault, text: Self.text)
        #expect(s.title == "Evil · Night" && s.body == "Your video is ready" && s.category == .video)
    }

    @Test func mediaFailureDownloadAndUpdateContent() {
        #expect(NotificationContent.make(NotificationEvent(kind: .video(failed: true), chatID: "c"), sound: .none, text: Self.text).body
                == "Your video didn't finish.")
        #expect(NotificationContent.make(NotificationEvent(kind: .image(failed: true), chatID: "c"), sound: .none, text: Self.text).body
                == "Your picture didn't finish.")
        let d = NotificationContent.make(NotificationEvent(kind: .download(pack: "Photo")), sound: .none, text: Self.text)
        #expect(d.body == "Photo is ready" && d.category == .download && d.userInfo == ["category": "download"] && d.threadID == nil)
        let u = NotificationContent.make(NotificationEvent(kind: .update(version: "1.1")), sound: .none, text: Self.text)
        #expect(u.body == "AntiChat 1.1 is ready — restart to update" && u.category == .update)
    }

    @Test func systemSoundsAreListed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in ["Tink.aiff", "Basso.aiff", "readme.txt"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
        #expect(NotificationSound.systemSoundNames(directory: dir) == ["Basso", "Tink"])
        #expect(NotificationSound(rawValue: "default") == .systemDefault && NotificationSound(rawValue: "none") == .none)
        #expect(NotificationSound(rawValue: "Glass").rawValue == "Glass")
    }
}
