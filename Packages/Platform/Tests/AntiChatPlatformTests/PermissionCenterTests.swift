// M3.T02 step 5: PermissionCenter maps TCC states, asks only on request, re-checks on app activation, and the
// `-FakePermission` override parses. No real TCC database is touched (injected `PermissionSystem`).
@preconcurrency import AVFoundation
import AntiChatFoundation
import AppKit
import Foundation
import Synchronization
import Testing

@testable import AntiChatPlatform

final class FakeTCC: Sendable {
    let status = Mutex<AVAuthorizationStatus>(.notDetermined)
    let device = Mutex(true)
    let requests = Mutex(0)
    let opened = Mutex<[URL]>([])
    let answer: Bool

    init(_ s: AVAuthorizationStatus, answer: Bool = true) {
        status.withLock { $0 = s }
        self.answer = answer
    }

    var system: PermissionSystem {
        PermissionSystem(
            microphoneStatus: { self.status.withLock { $0 } },
            requestMicrophone: {
                self.requests.withLock { $0 += 1 }
                let a = self.answer
                self.status.withLock { $0 = a ? .authorized : .denied }
                return a
            },
            hasMicrophone: { self.device.withLock { $0 } },
            open: { u in self.opened.withLock { $0.append(u) } })
    }
}

@MainActor @Suite struct PermissionCenterTests {
    @Test func mapsEveryAuthorizationStatus() {
        let cases: [(AVAuthorizationStatus, PermissionStatus, MicAvailability)] = [
            (.notDetermined, .notDetermined, .needsPermission), (.authorized, .granted, .ready),
            (.denied, .denied, .denied), (.restricted, .restricted, .denied),
        ]
        for (av, status, avail) in cases {
            let c = PermissionCenter(system: FakeTCC(av).system, observeActivation: false)
            #expect(c.status(.microphone) == status)
            #expect(c.micAvailability == avail)
        }
        #expect(PermissionStatus.denied.needsSystemSettings && PermissionStatus.restricted.needsSystemSettings)
        #expect(!PermissionStatus.notDetermined.needsSystemSettings)
    }

    @Test func neverAsksUntilRequested() async {
        let tcc = FakeTCC(.notDetermined)
        let c = PermissionCenter(system: tcc.system, observeActivation: false)
        c.refresh()
        _ = c.micAvailability
        #expect(tcc.requests.withLock { $0 } == 0)
        #expect(c.requestCount == 0)
        #expect(await c.request(.microphone))
        #expect(tcc.requests.withLock { $0 } == 1)
        #expect(c.micAvailability == .ready)
        // Already decided: the system dialog is not shown again.
        #expect(await c.request(.microphone))
        #expect(tcc.requests.withLock { $0 } == 1)
    }

    @Test func deniedRequestLeadsToSystemSettings() async {
        let tcc = FakeTCC(.notDetermined, answer: false)
        let c = PermissionCenter(system: tcc.system, observeActivation: false)
        #expect(!(await c.request(.microphone)))
        #expect(c.micAvailability == .denied)
        c.openSystemSettings(.microphone)
        #expect(tcc.opened.withLock { $0 }.map(\.absoluteString)
            == ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"])
    }

    @Test func noDeviceWinsOverPermission() {
        let tcc = FakeTCC(.authorized)
        tcc.device.withLock { $0 = false }
        let c = PermissionCenter(system: tcc.system, observeActivation: false)
        #expect(c.micAvailability == .noDevice)
        tcc.device.withLock { $0 = true }
        c.refresh()
        #expect(c.micAvailability == .ready)
    }

    @Test func rechecksWhenTheAppBecomesActive() async {
        let tcc = FakeTCC(.denied)
        let c = PermissionCenter(system: tcc.system)
        #expect(c.microphone == .denied)
        tcc.status.withLock { $0 = .authorized }  // the user flipped it in System Settings
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        for _ in 0..<200 where c.microphone != .granted { await Task.yield() }  // main-queue delivery
        #expect(c.microphone == .granted)
    }

    @Test func fakeSystemFollowsTheDialog() async {
        let c = PermissionCenter(system: .fake(microphone: .notDetermined), observeActivation: false)
        #expect(c.micAvailability == .needsPermission)
        #expect(await c.request(.microphone))
        let d = PermissionCenter(system: .fake(microphone: .denied), observeActivation: false)
        #expect(!(await d.request(.microphone)))
        #expect(d.micAvailability == .denied)
    }

    @Test func fakePermissionLaunchArgumentParses() {
        let o = LaunchOptions.parse(["AntiChat", "-FakePermission", "microphone=denied,accessibility=granted"])
        #expect(o.fakePermissions == ["microphone": "denied", "accessibility": "granted"])
        let bad = LaunchOptions.parse(["AntiChat", "-FakePermission", "microphone=maybe"])
        #expect(bad.fakePermissions.isEmpty)
        #expect(!bad.errors.isEmpty)
    }
}
