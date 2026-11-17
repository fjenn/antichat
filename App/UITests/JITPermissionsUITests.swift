// AT-109 UI leg (M8.T14; R-109 AC1–AC2): the just-in-time matrix on the real app after
// `tccutil reset All app.antichat.AntiChat.dev` [perm]: onboarding (journey 1) requests nothing; the microphone is
// asked on the first mic click, notifications on the first event that would notify, location when its switch is
// turned on — each after its one-sentence explainer; nothing requests Screen Recording anywhere in v1 (R-107 is M11);
// each denied state shows its inline fix with Open System Settings (system alerts via addUIInterruptionMonitor).
// Committed, not run on this Mac (Q-015). What runs today: tools/at/at-109-probe.sh (permission-calls lint,
// MacIntegrationProbe modes jit / jit-denied, the AT-108 notifications leg, the unified-log TCC count) and
// PermissionCoordinatorTests / PermissionCenterTests.
import XCTest

final class JITPermissionsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    let since = Date()

    @MainActor
    func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-OfflineOnly", "YES"] + extra)
        app.launch()
        return app
    }

    /// `tools/ci/tcc-requests.sh` for one service since the test started.
    func tccRequests(_ service: String) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/ci/tcc-requests.sh").path
        p.arguments = [script, "app.antichat.AntiChat.dev", f.string(from: since), service]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Int(s.split(separator: "=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
    }

    @MainActor
    func testOnboardingRequestsNothing() {
        let app = launch(["-ResetOnboarding", "YES", "-UseScriptedEngine", "basic"])
        let open = app.buttons["Open chat"]
        // Each step's primary button is `onb.cta.*` (Q-015 r2: `onboarding.continue` never existed).
        let cta = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'onb.cta.'")).firstMatch
        for _ in 0..<8 where !open.exists {
            guard cta.waitForExistence(timeout: 10) else { break }
            cta.click()
        }
        if open.exists { open.click() }
        for svc in ["kTCCServiceMicrophone", "kTCCServiceScreenCapture", "kTCCServiceAccessibility", "kTCCServiceListenEvent",
                    "kTCCServiceLocation"] {
            XCTAssertEqual(tccRequests(svc), 0, svc)
        }
    }

    @MainActor
    func testMicOnFirstUse() {
        let app = launch(["-SkipOnboarding", "YES", "-FakeVoiceInstalled", "YES", "-FakePermission", "microphone=notDetermined",
                          "-UseScriptedVoice", "dictation-anatomy"])
        XCTAssertEqual(tccRequests("kTCCServiceMicrophone"), 0, "not at launch")
        app.buttons["composer.mic"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "permissionPromptSheet").firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["voice.permission"].exists, "the one-sentence explainer first")
        app.buttons["voice.permission.continue"].click()
    }

    @MainActor
    func testNotificationsOnFirstEvent() {
        // Q-015 r5: `basic` answers in ~160 ms, so the reply ended while AntiChat was still focused (no notifying event,
        // no explainer). A 3 s reply ends after ⌘H, as a reply the user leaves the app for does.
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("jit-notif-\(UUID().uuidString).jsonl")
        let words = (0..<20).map { #"{"t":"textDelta","v":" word\#($0)","delayMs":150}"# }.joined(separator: "\n")
        try? Data((words + "\n" + #"{"t":"done","reason":"stop"}"# + "\n").utf8).write(to: script)
        let app = launch(["-SkipOnboarding", "YES", "-FakePermission", "notifications=notDetermined", "-UseScriptedEngine", script.path])
        let input = app.descendants(matching: .any).matching(identifier: "composerText").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("Hello\r")
        app.typeKey("h", modifierFlags: .command)  // hide AntiChat: unfocused without launching another app (Q-015 catch-up)
        // r6: activating right after ⌘H brought AntiChat back ~0.1 s later, so the 3 s reply still ended in focus (no
        // notifying event). Stay away until the reply has ended, as the user who left does, then come back.
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notificationExplainer").firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testLocationOnEnable() {
        // The switch is on by default (2026-11-16); this leg is the user turning it on in Settings.
        let app = launch(["-SkipOnboarding", "YES", "-FakePermission", "location=notDetermined", "-searchUsesLocation", "NO"])
        app.typeKey(",", modifierFlags: .command)
        app.descendants(matching: .any).matching(identifier: "settings.nav.capabilities").firstMatch.click()
        app.descendants(matching: .any).matching(identifier: "settings.control.searchUsesLocation").firstMatch.click()  // a CheckBox on macOS
        XCTAssertTrue(app.staticTexts["location.explainer.text"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testNoScreenRecordingRequestAnywhere() {
        // Run after the whole UI suite (scheme order): no kTCCServiceScreenCapture request from AntiChat at all.
        XCTAssertEqual(tccRequests("kTCCServiceScreenCapture"), 0)
    }

    @MainActor
    func testDeniedStatesShowFix() {
        let app = launch(["-SkipOnboarding", "YES", "-FakeVoiceInstalled", "YES", "-NotificationSpy", NSTemporaryDirectory() + "jit-spy.json",
                          "-FakePermission", "microphone=denied,location=denied,notifications=denied"])
        app.buttons["composer.mic"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "permissionDeniedPopover").firstMatch.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "notificationsDeniedBanner").firstMatch.waitForExistence(timeout: 5))
    }
}
