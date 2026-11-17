// M8.T14 step 5 (R-109, G-065 M8 part; P-shell-20): the one place AntiChat asks macOS for a privacy permission.
// Every request is just in time, from the object that needs it, and is preceded by its one-sentence in-app
// explainer; a denied permission has an inline fix with [Open System Settings] on that object (IS-10). Onboarding
// never asks. `tools/ci/permission-calls.py` fails when a system request API appears anywhere else (except the
// vendored `SystemPermissionService.swift`).
//
//   Microphone          first mic / voice click (M3: PermissionPromptSheet `voice.permission`, then this request)
//   Notifications       the first event that would notify (M8.T12: banner `perm.notifications.why`)
//   Location            turning on "Use my approximate location for search" (M8.T08: `perm.location.why`)
//   Accessibility,      global dictation, moved to M11 (D-026): the kinds stay, nothing in v1 requests them
//   Input Monitoring
//   Screen Recording    first screenshot / window attach (R-107, moved to M11 with M8.T15): nothing in v1 requests it
//
// The system calls are injected (`System`): tests and `-FakePermission <kind>=<state>` never touch TCC.
@preconcurrency import AVFoundation
import AntiChatFoundation
import AppKit
import ApplicationServices
@preconcurrency import CoreLocation
import Foundation
import Observation
import UserNotifications

/// Every permission the coordinator knows (the R-109 matrix).
public enum PermissionRequestKind: String, Sendable, CaseIterable, Codable {
    case microphone, notifications, location, accessibility, inputMonitoring, screenRecording

    /// The copy key of the one-sentence explainer shown before the request.
    public var explainerKey: String {
        switch self {
        case .microphone: "voice.permission"
        case .notifications: "perm.notifications.why"
        case .location: "perm.location.why"
        case .accessibility, .inputMonitoring: "permission.accessibility"
        case .screenRecording: "perm.screenRecording.why"
        }
    }

    /// The copy key of the inline fix shown where the permission was needed, once it is denied.
    public var deniedKey: String {
        switch self {
        case .microphone: "voice.denied"
        case .notifications: "permission.notifications.off"
        case .location: "perm.location.denied"
        case .accessibility, .inputMonitoring: "permission.accessibility"
        case .screenRecording: "perm.screenRecording.denied"
        }
    }

    /// System Settings › the pane that fixes it.
    public var settingsURL: URL {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        return switch self {
        case .microphone: URL(string: base + "Privacy_Microphone")!
        case .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=app.antichat.AntiChat")!
        case .location: URL(string: base + "Privacy_LocationServices")!
        case .accessibility: URL(string: base + "Privacy_Accessibility")!
        case .inputMonitoring: URL(string: base + "Privacy_ListenEvent")!
        case .screenRecording: URL(string: base + "Privacy_ScreenCapture")!
        }
    }

    /// Requested by something that ships in v1 (the others moved to M11 with global dictation and R-107, D-026).
    public var requestedInV1: Bool { self == .microphone || self == .notifications || self == .location }
}

/// The inline fix a denied permission shows on the object that needed it (IS-10).
public struct PermissionInlineFix: Sendable, Equatable {
    public var kind: PermissionRequestKind
    /// The sentence (copy key).
    public var messageKey: String
    /// [Open System Settings] (`perm.openSettings`) opens this.
    public var settingsURL: URL
}

@MainActor @Observable
public final class PermissionCoordinator {
    public static let shared = PermissionCoordinator(system: PermissionCoordinator.systemFromLaunchOptions())

    /// The system calls (live: the only request APIs of the app; fakes: tests and `-FakePermission`).
    public struct System: Sendable {
        public var status: @Sendable (PermissionRequestKind) async -> PermissionStatus
        /// Shows the macOS dialog (it appears only from `.notDetermined`); true = granted.
        public var request: @Sendable (PermissionRequestKind) async -> Bool
        public var open: @Sendable (URL) -> Void

        public init(status: @escaping @Sendable (PermissionRequestKind) async -> PermissionStatus,
                    request: @escaping @Sendable (PermissionRequestKind) async -> Bool,
                    open: @escaping @Sendable (URL) -> Void = { _ in }) {
            self.status = status
            self.request = request
            self.open = open
        }
    }

    /// One coordinator action, in order (the "explainer before request" spy, AT-109).
    public enum Step: Sendable, Equatable {
        case explained(PermissionRequestKind)
        case requested(PermissionRequestKind)
        /// The explainer was answered with Not now (no system dialog).
        case declined(PermissionRequestKind)
        case openedSettings(PermissionRequestKind)
    }

    @ObservationIgnored public let system: System
    /// Shows `kind`'s explainer and returns true for Allow (set by the app's UI; nil = nobody can explain, so no
    /// request is made).
    @ObservationIgnored public var explainer: (@MainActor (PermissionRequestKind) async -> Bool)?
    public private(set) var steps: [Step] = []
    /// The last known status per kind (refreshed on app activation and after each request).
    public private(set) var statuses: [PermissionRequestKind: PermissionStatus] = [:]
    /// Kinds whose explainer got Not now in this launch: not asked again until the next launch.
    @ObservationIgnored private var declinedThisLaunch: Set<PermissionRequestKind> = []
    @ObservationIgnored private var inFlight: [PermissionRequestKind: Task<Bool, Never>] = [:]
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    /// Where a final Not now is kept (the app's store; tests pass their own so one test's answer is not the next one's).
    private let defaults: UserDefaults

    public init(system: System, observeActivation: Bool = true, defaults: UserDefaults = AppDefaults.standard) {
        self.system = system
        self.defaults = defaults
        if observeActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshAll() } }
        }
    }

    public func status(_ kind: PermissionRequestKind) async -> PermissionStatus {
        let s = await system.status(kind)
        if statuses[kind] != s { statuses[kind] = s }
        return s
    }

    /// Tests: forget what this Mac answered for `kind` (a snapshot of a page must not show this Mac's denied banner).
    public func debugForgetStatus(_ kind: PermissionRequestKind) { statuses[kind] = nil }

    public func refreshAll() {
        // Location is left to LocationPermission (review fix: its CoreLocation manager is created only once the user
        // opens the location setting, never by an app activation).
        Task { for k in [PermissionRequestKind.notifications, .microphone] { _ = await status(k) } }
    }

    /// The inline fix for `kind` when it is denied or restricted, else nil.
    public func inlineFix(_ kind: PermissionRequestKind) -> PermissionInlineFix? {
        guard statuses[kind]?.needsSystemSettings == true else { return nil }
        return PermissionInlineFix(kind: kind, messageKey: kind.deniedKey, settingsURL: kind.settingsURL)
    }

    public func openSystemSettings(_ kind: PermissionRequestKind) {
        steps.append(.openedSettings(kind))
        system.open(kind.settingsURL)
    }

    /// A flow with an explainer view of its own (the microphone sheet, the location explainer) reports it here.
    public func recordExplained(_ kind: PermissionRequestKind) { steps.append(.explained(kind)) }

    /// A request made through PermissionCenter / LocationPermission (their system calls are this file's `live`).
    public func recordRequested(_ kind: PermissionRequestKind) { steps.append(.requested(kind)) }

    /// Requests with no explainer of the same kind before them (must stay empty: AT-109 AC2).
    public var requestedWithoutExplainer: [PermissionRequestKind] {
        var explained = Set<PermissionRequestKind>()
        var bad: [PermissionRequestKind] = []
        for s in steps {
            switch s {
            case .explained(let k): explained.insert(k)
            case .requested(let k): if !explained.contains(k) { bad.append(k) }
            default: break
            }
        }
        return bad
    }

    /// The system dialog for `kind`, after the caller has shown its explainer (the mic button's sheet, the location
    /// row's explainer). The only path to a system request.
    @discardableResult
    public func requestAfterExplainer(_ kind: PermissionRequestKind) async -> Bool {
        steps.append(.requested(kind))
        let granted = await system.request(kind)
        _ = await status(kind)
        return granted
    }

    /// Granted already, or — from `.notDetermined` — the explainer (once per launch) and then the request.
    /// Denied / restricted: false (the inline fix shows where it is needed). Concurrent callers share one prompt.
    public func ensure(_ kind: PermissionRequestKind) async -> Bool {
        if let t = inFlight[kind] { return await t.value }
        let t = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            switch await self.status(kind) {
            case .granted: return true
            case .denied, .restricted: return false
            case .notDetermined:
                guard !self.declinedThisLaunch.contains(kind), !self.declinedForGood(kind), let explainer = self.explainer else { return false }
                self.steps.append(.explained(kind))
                guard await explainer(kind) else {
                    self.steps.append(.declined(kind))
                    self.declinedThisLaunch.insert(kind)
                    // Not now on the notifications banner is an answer, not a snooze: the banner never comes back
                    // by itself (it used to return after every launch). Settings › Notifications asks again (`askNow`).
                    if kind == .notifications { self.defaults.set(true, forKey: Self.declinedKey(kind)) }
                    return false
                }
                return await self.requestAfterExplainer(kind)
            }
        }
        inFlight[kind] = t
        let granted = await t.value
        inFlight[kind] = nil
        return granted
    }

    /// M8.T12 step 4.
    public func ensureNotifications() async -> Bool { await ensure(.notifications) }

    static func declinedKey(_ kind: PermissionRequestKind) -> String { "permission.declined.\(kind.rawValue)" }
    func declinedForGood(_ kind: PermissionRequestKind) -> Bool { defaults.bool(forKey: Self.declinedKey(kind)) }

    /// The user asked for it themselves (a Settings switch): forgets an earlier Not now and goes straight to the
    /// system's request, without the explainer banner.
    public func askNow(_ kind: PermissionRequestKind) async -> Bool {
        defaults.removeObject(forKey: Self.declinedKey(kind))
        declinedThisLaunch.remove(kind)
        switch await status(kind) {
        case .granted: return true
        case .denied, .restricted: return false
        case .notDetermined: return await requestAfterExplainer(kind)
        }
    }

    // MARK: System

    /// The live system calls: the only request APIs in the app (permission-calls.py).
    public nonisolated static let live = System(
        status: { kind in
            switch kind {
            case .microphone: return PermissionStatus(AVCaptureDevice.authorizationStatus(for: .audio))
            case .notifications:
                guard Bundle.main.bundleIdentifier != nil else { return .denied }  // headless: no center
                let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                switch s {
                case .authorized, .provisional, .ephemeral: return .granted
                case .denied: return .denied
                case .notDetermined: return .notDetermined
                @unknown default: return .notDetermined
                }
            case .location:
                return switch LocationSystem.live.status() {
                case .granted: .granted
                case .notDetermined: .notDetermined
                case .restricted: .restricted
                case .denied, .servicesOff: .denied
                }
            case .accessibility: return AXIsProcessTrusted() ? .granted : .notDetermined
            case .inputMonitoring: return CGPreflightListenEventAccess() ? .granted : .notDetermined
            case .screenRecording: return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
            }
        },
        request: { kind in
            switch kind {
            case .microphone: return await AVCaptureDevice.requestAccess(for: .audio)
            case .notifications:
                guard Bundle.main.bundleIdentifier != nil else { return false }
                return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            case .location:
                LocationSystem.live.request()  // the answer arrives through LocationPermission's delegate
                return false
            case .accessibility:
                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                return AXIsProcessTrustedWithOptions(opts)
            case .inputMonitoring: return CGRequestListenEventAccess()
            case .screenRecording: return CGRequestScreenCaptureAccess()
            }
        },
        open: { url in Task { @MainActor in NSWorkspace.shared.open(url) } })

    /// CoreLocation's When-In-Use dialog for `manager` (LocationPermission's lazily created manager, main thread).
    public nonisolated static func requestWhenInUse(_ manager: CLLocationManager) {
        manager.requestWhenInUseAuthorization()
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// `-FakePermission <kind>=<state>` (DEBUG): fixed states; a request from `.notDetermined` grants unless
    /// `<kind>Answer=denied` is given (`-FakePermission notifications=notDetermined,notificationsAnswer=denied`).
    public nonisolated static func fake(_ states: [PermissionRequestKind: PermissionStatus], answers: [PermissionRequestKind: PermissionStatus] = [:],
                            opened: (@Sendable (URL) -> Void)? = nil) -> System {
        let box = FakeStates(states)
        return System(
            status: { box.get($0) },
            request: { kind in
                if box.get(kind) == .notDetermined { box.set(kind, answers[kind] ?? .granted) }
                return box.get(kind) == .granted
            },
            open: opened ?? { _ in })
    }

    final class FakeStates: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PermissionRequestKind: PermissionStatus]
        init(_ v: [PermissionRequestKind: PermissionStatus]) { values = v }
        func get(_ k: PermissionRequestKind) -> PermissionStatus { lock.withLock { values[k] ?? .notDetermined } }
        func set(_ k: PermissionRequestKind, _ s: PermissionStatus) { lock.withLock { values[k] = s } }
    }
    #endif

    nonisolated static func systemFromLaunchOptions() -> System {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let fakes = LaunchOptions.current.fakePermissions
        var states: [PermissionRequestKind: PermissionStatus] = [:]
        var answers: [PermissionRequestKind: PermissionStatus] = [:]
        for (k, v) in fakes {
            if k.hasSuffix("Answer"), let kind = PermissionRequestKind(rawValue: String(k.dropLast(6))), let s = PermissionStatus(rawValue: v) {
                answers[kind] = s
            } else if let kind = PermissionRequestKind(rawValue: k), let s = PermissionStatus(rawValue: v) {
                states[kind] = s
            }
        }
        if !states.isEmpty {
            let states = states, answers = answers
            // Kinds not named keep their live status reads; a request for them is never made from a faked run.
            let live = Self.live
            let box = FakeStates(states)
            let opened = LaunchOptions.current.notificationSpy.map { URL(fileURLWithPath: $0).deletingLastPathComponent()
                .appendingPathComponent("opened-urls.txt") }
            return System(
                status: { kind in states[kind] != nil ? box.get(kind) : await live.status(kind) },
                request: { kind in
                    guard states[kind] != nil else { return false }
                    if box.get(kind) == .notDetermined { box.set(kind, answers[kind] ?? .granted) }
                    return box.get(kind) == .granted
                },
                open: { url in
                    if let opened {
                        // Q-015 r4: the spy's folder exists only once a notification was recorded; a denied run has none.
                        try? FileManager.default.createDirectory(at: opened.deletingLastPathComponent(), withIntermediateDirectories: true)
                        let line = url.absoluteString + "\n"
                        if let h = try? FileHandle(forWritingTo: opened) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                        else { try? line.write(to: opened, atomically: true, encoding: .utf8) }
                    }
                    // Never the real System Settings from a faked run (no focus steal, BackgroundRun).
                })
        }
        #endif
        return live
    }
}
