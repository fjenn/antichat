// M8.T12 / AT-108: the post pipeline — flag, policy, just-in-time permission (explainer before the request, never
// at launch), denied → nothing, delivered → the spy holds the request with the chosen sound.
import AntiChatFoundation
import Foundation
import Testing

@testable import AntiChatPlatform

@MainActor @Suite struct NotificationServiceTests {
    func make(_ status: PermissionStatus, answer: PermissionStatus = .granted, explain: Bool? = true)
        -> (NotificationService, SpyUserNotificationClient, PermissionCoordinator) {
        let perms = PermissionCoordinator(system: PermissionCoordinator.fake([.notifications: status], answers: [.notifications: answer]),
                                          observeActivation: false, defaults: .inMemory())
        if let explain { perms.explainer = { _ in explain } }
        let spy = SpyUserNotificationClient()
        let s = NotificationService(client: spy, permissions: perms)
        s.text = NotificationRouterTests.text
        return (s, spy, perms)
    }

    let away = NotificationPolicy.Focus(appActive: false, mainWindowKey: false, chatVisible: false)
    let looking = NotificationPolicy.Focus(appActive: true, mainWindowKey: true, chatVisible: true)
    let answer = NotificationEvent(kind: .answer, chatID: "c1", messageID: "m1", chatTitle: "T")

    @Test func firstEventExplainsThenRequestsThenDelivers() async {
        let (s, spy, perms) = make(.notDetermined)
        #expect(perms.steps.isEmpty, "nothing asked at launch")
        #expect(await s.post(answer, focus: away) == .delivered)
        #expect(perms.steps == [.explained(.notifications), .requested(.notifications)], "explainer before the request")
        #expect(spy.requests.count == 1 && spy.requests[0].category == .answer)
        #expect(await s.post(answer, focus: away) == .delivered)
        #expect(perms.steps.count == 2, "granted: no second explainer or request")
    }

    @Test func notNowAsksNoSystemDialogAndNotAgainThisLaunch() async {
        let (s, spy, perms) = make(.notDetermined, explain: false)
        #expect(await s.post(answer, focus: away) == .notAllowed)
        #expect(await s.post(answer, focus: away) == .notAllowed)
        #expect(perms.steps == [.explained(.notifications), .declined(.notifications)])
        #expect(spy.requests.isEmpty)
    }

    @Test func noExplainerNoRequest() async {
        let (s, spy, perms) = make(.notDetermined, explain: nil)
        #expect(await s.post(answer, focus: away) == .notAllowed)
        #expect(perms.steps.isEmpty && spy.requests.isEmpty)
    }

    @Test func deniedDeliversNothingAndShowsTheFix() async {
        let (s, spy, perms) = make(.denied)
        #expect(await s.post(answer, focus: away) == .notAllowed)
        #expect(spy.requests.isEmpty && perms.steps.isEmpty)
        let fix = perms.inlineFix(.notifications)
        #expect(fix?.messageKey == "permission.notifications.off")
        #expect(fix?.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.antichat.AntiChat")
    }

    @Test func policyGatesBeforeAnyPermissionStep() async {
        let (s, spy, perms) = make(.notDetermined)
        #expect(await s.post(answer, focus: looking) == .suppressed)
        s.policy = { NotificationPolicy(when: .never) }
        #expect(await s.post(answer, focus: away) == .suppressed)
        s.policy = { NotificationPolicy(when: .always, groups: [.media]) }
        #expect(await s.post(answer, focus: away) == .suppressed, "Responses off")
        #expect(perms.steps.isEmpty && spy.requests.isEmpty, "a suppressed event never triggers the explainer")
        s.policy = { NotificationPolicy(when: .always) }
        #expect(await s.post(answer, focus: looking) == .delivered, "Always: also while looking at it")
    }

    @Test func soundFollowsTheSetting() async {
        let (s, spy, _) = make(.granted)
        s.sound = { .named("Submarine") }
        _ = await s.post(answer, focus: away)
        s.sound = { .none }
        _ = await s.post(answer, focus: away)
        #expect(spy.requests.map(\.sound) == ["Submarine.aiff", nil])
    }

    @Test func concurrentEventsShareOneExplainer() async {
        let perms = PermissionCoordinator(system: PermissionCoordinator.fake([.notifications: .notDetermined]), observeActivation: false, defaults: .inMemory())
        var shown = 0
        perms.explainer = { _ in
            shown += 1
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        async let a = perms.ensureNotifications()
        async let b = perms.ensureNotifications()
        let (x, y) = await (a, b)
        #expect(x && y && shown == 1)
    }

    @Test func spyWritesTheRequestsFile() async throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("spy-\(UUID().uuidString)/requests.json")
        defer { try? FileManager.default.removeItem(at: f.deletingLastPathComponent()) }
        let spy = SpyUserNotificationClient(file: f)
        let spec = NotificationContent.make(answer, sound: .systemDefault, id: "r1", text: NotificationRouterTests.text)
        try await spy.add(spec)
        let decoded = try JSONDecoder().decode([NotificationRequestSpec].self, from: Data(contentsOf: f))
        #expect(decoded == [spec])
    }

    @Test func spyLaunchOptionParses() {
        #expect(LaunchOptions.parse(["app", "-NotificationSpy", "/tmp/r.json"]).notificationSpy == "/tmp/r.json")
    }
}
