// M8.T14 / AT-109 (R-109 AC1–AC2): the just-in-time matrix. For every kind the coordinator shows the explainer before
// the system request (spy order), never asks without an explainer or after Not now in the same launch, never asks
// again once decided, and a denied kind has its inline fix with the right System Settings pane. Microphone and
// Location requests that come through their own objects (PermissionCenter, LocationPermission) land in the same
// step log, and the v1 matrix requests only Microphone, Notifications and Location.
import AntiChatFoundation
import Foundation
import Testing

@testable import AntiChatPlatform

@MainActor @Suite struct PermissionCoordinatorTests {
    func make(_ states: [PermissionRequestKind: PermissionStatus], answers: [PermissionRequestKind: PermissionStatus] = [:],
              explain: Bool? = true) -> (PermissionCoordinator, Box) {
        let box = Box()
        let c = PermissionCoordinator(system: PermissionCoordinator.fake(states, answers: answers, opened: { u in box.add(u) }),
                                      observeActivation: false, defaults: .inMemory())
        if let explain { c.explainer = { kind in box.explained.append(kind); return explain } }
        return (c, box)
    }

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var opened: [URL] = []
        var explained: [PermissionRequestKind] = []
        func add(_ u: URL) { lock.withLock { opened.append(u) } }
    }

    @Test func everyKindExplainsBeforeItsRequest() async {
        for kind in PermissionRequestKind.allCases {
            let (c, box) = make([kind: .notDetermined])
            #expect(c.steps.isEmpty, "\(kind): nothing at creation (launch)")
            #expect(await c.ensure(kind))
            #expect(c.steps == [.explained(kind), .requested(kind)], "\(kind): explainer first")
            #expect(box.explained == [kind])
            #expect(await c.ensure(kind), "granted stays granted")
            #expect(c.steps.count == 2, "\(kind): no second explainer or dialog once decided")
        }
    }

    @Test func notNowMeansNoDialogUntilTheNextLaunch() async {
        for kind in PermissionRequestKind.allCases {
            let (c, _) = make([kind: .notDetermined], explain: false)
            #expect(!(await c.ensure(kind)))
            #expect(!(await c.ensure(kind)))
            #expect(c.steps == [.explained(kind), .declined(kind)], "\(kind)")
        }
    }

    @Test func noExplainerMeansNoRequest() async {
        let (c, _) = make([.microphone: .notDetermined, .notifications: .notDetermined], explain: nil)
        #expect(!(await c.ensure(.microphone)))
        #expect(!(await c.ensure(.notifications)))
        #expect(c.steps.isEmpty)
    }

    @Test func deniedShowsTheInlineFixWithItsPane() async {
        let panes: [PermissionRequestKind: String] = [
            .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.antichat.AntiChat",
            .location: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            .inputMonitoring: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            .screenRecording: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for kind in PermissionRequestKind.allCases {
            let (c, box) = make([kind: .denied])
            #expect(c.inlineFix(kind) == nil, "unknown until read")
            #expect(!(await c.ensure(kind)))
            #expect(c.steps.isEmpty, "\(kind): denied → no explainer, no dialog")
            let fix = c.inlineFix(kind)
            #expect(fix?.settingsURL.absoluteString == panes[kind], "\(kind)")
            #expect(fix?.messageKey == kind.deniedKey)
            c.openSystemSettings(kind)
            #expect(box.opened.last?.absoluteString == panes[kind])
            #expect(c.steps == [.openedSettings(kind)])
        }
        let (r, _) = make([.microphone: .restricted])
        _ = await r.status(.microphone)
        #expect(r.inlineFix(.microphone) != nil, "restricted also needs System Settings")
    }

    @Test func deniedAtTheDialogShowsTheFixAfterwards() async {
        let (c, _) = make([.location: .notDetermined], answers: [.location: .denied])
        #expect(!(await c.ensure(.location)))
        #expect(c.steps == [.explained(.location), .requested(.location)])
        #expect(c.inlineFix(.location)?.messageKey == "perm.location.denied")
    }

    @Test func explainerSentencesExist() {
        #expect(PermissionRequestKind.microphone.explainerKey == "voice.permission")
        #expect(PermissionRequestKind.notifications.explainerKey == "perm.notifications.why")
        #expect(PermissionRequestKind.location.explainerKey == "perm.location.why")
        #expect(PermissionRequestKind.accessibility.explainerKey == "permission.accessibility")
    }

    @Test func v1RequestsOnlyMicNotificationsAndLocation() {
        #expect(PermissionRequestKind.allCases.filter(\.requestedInV1) == [.microphone, .notifications, .location])
    }

    @Test func ownFlowsLandInTheSameLog() async {
        // The microphone sheet and the location explainer are views of their own; they report to the coordinator.
        let (c, _) = make([:])
        c.recordExplained(.microphone)
        c.recordRequested(.microphone)
        c.recordExplained(.location)
        c.recordRequested(.location)
        #expect(c.steps == [.explained(.microphone), .requested(.microphone), .explained(.location), .requested(.location)])
        #expect(c.requestedWithoutExplainer.isEmpty)
        c.recordRequested(.notifications)
        #expect(c.requestedWithoutExplainer == [.notifications], "a request with no explainer before it is flagged")
    }

    @Test func fakePermissionStatesReachTheCoordinator() {
        let o = LaunchOptions.parse(["AntiChat", "-FakePermission", "notifications=notDetermined,notificationsAnswer=denied,location=denied"])
        #expect(o.fakePermissions["notifications"] == "notDetermined")
        #expect(o.fakePermissions["notificationsAnswer"] == "denied")
        #expect(o.fakePermissions["location"] == "denied")
    }
}
