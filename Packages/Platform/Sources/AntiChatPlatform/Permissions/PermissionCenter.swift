// M3.T02 (R-050/R-052 permission states, R-109 prep; G-065; S-05 "asked the first time", S-24, IS-10): the one
// place the app reads and requests macOS privacy permissions. Microphone access is never requested before the
// user clicks a voice control (just in time), never during onboarding, and a denial always has a recovery
// action (System Settings). Status is re-read whenever the app becomes active, because the user changes it in
// System Settings while AntiChat is in the background.
//
// Capture runs in the XPC helper (AT-M0-05: the TCC prompt names "AntiChat" and Settings shows one entry), but
// TCC attributes the helper to the app, so the app's AVCaptureDevice status is the helper's status too.
// The status providers are injected so tests (and `-FakePermission`) never touch the real TCC database.
// M8.T08 (Privacy page) reuses this for accessibility, notifications and screen recording; the vendored
// Osaurus SystemPermissionService (P-shell-20, trimmed in UP-OS-018) stays the reference for those probes.
@preconcurrency import AVFoundation
import AntiChatFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation

public enum PermissionKind: String, Sendable, CaseIterable {
    case microphone, accessibility, notifications, screenRecording
}

public enum PermissionStatus: String, Sendable, Equatable {
    case notDetermined, granted, denied, restricted

    /// A voice control may start capture.
    public var allowsUse: Bool { self == .granted }
    /// The user must change it in System Settings (the system dialog will not appear again).
    public var needsSystemSettings: Bool { self == .denied || self == .restricted }

    init(_ av: AVAuthorizationStatus) {
        switch av {
        case .authorized: self = .granted
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }
}

/// What the microphone button shows (components.md `MicButton` states).
public enum MicAvailability: Equatable, Sendable {
    /// Granted and a device is present.
    case ready
    /// First click shows `PermissionPromptSheet` (`voice.permission`) before the system dialog.
    case needsPermission
    /// `PermissionDeniedPopover` (`voice.denied`, [Open System Settings]).
    case denied
    /// `voice.noDevice` (IS-10).
    case noDevice
}

/// The system calls PermissionCenter makes; replaced in tests and by `-FakePermission`.
public struct PermissionSystem: Sendable {
    public var microphoneStatus: @Sendable () -> AVAuthorizationStatus
    public var requestMicrophone: @Sendable () async -> Bool
    public var hasMicrophone: @Sendable () -> Bool
    public var accessibilityTrusted: @Sendable () -> Bool
    public var screenRecordingGranted: @Sendable () -> Bool
    public var open: @Sendable (URL) -> Void

    public init(
        microphoneStatus: @escaping @Sendable () -> AVAuthorizationStatus,
        requestMicrophone: @escaping @Sendable () async -> Bool,
        hasMicrophone: @escaping @Sendable () -> Bool,
        accessibilityTrusted: @escaping @Sendable () -> Bool = { false },
        screenRecordingGranted: @escaping @Sendable () -> Bool = { false },
        open: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.microphoneStatus = microphoneStatus
        self.requestMicrophone = requestMicrophone
        self.hasMicrophone = hasMicrophone
        self.accessibilityTrusted = accessibilityTrusted
        self.screenRecordingGranted = screenRecordingGranted
        self.open = open
    }

    public static let live = PermissionSystem(
        microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
        requestMicrophone: { await PermissionCoordinator.live.request(.microphone) },  // M8.T14: the one request site
        hasMicrophone: {
            !AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
                .devices.isEmpty
        },
        accessibilityTrusted: { AXIsProcessTrusted() },
        screenRecordingGranted: { CGPreflightScreenCaptureAccess() },
        open: { url in Task { @MainActor in NSWorkspace.shared.open(url) } }
    )

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// `-FakePermission microphone=<state>`: status fixed to `state`; `request` grants only from `notDetermined`
    /// when `grantOnRequest` (the system dialog's Allow), and records nothing in TCC.
    public static func fake(microphone state: PermissionStatus, grantOnRequest: Bool = true, hasMicrophone: Bool = true) -> PermissionSystem {
        let box = FakeState(state)
        return PermissionSystem(
            microphoneStatus: { box.av },
            requestMicrophone: {
                if box.status == .notDetermined { box.status = grantOnRequest ? .granted : .denied }
                return box.status == .granted
            },
            hasMicrophone: { hasMicrophone })
    }

    final class FakeState: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PermissionStatus
        init(_ v: PermissionStatus) { value = v }
        var status: PermissionStatus {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        var av: AVAuthorizationStatus {
            switch status {
            case .granted: .authorized
            case .denied: .denied
            case .restricted: .restricted
            case .notDetermined: .notDetermined
            }
        }
    }
    #endif
}

@MainActor @Observable
public final class PermissionCenter {
    public static let shared = PermissionCenter(system: PermissionCenter.systemFromLaunchOptions())

    /// System Settings › Privacy & Security panes.
    public static func settingsURL(_ kind: PermissionKind) -> URL {
        let anchor = switch kind {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .notifications: "Notifications"
        }
        if kind == .notifications { return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")! }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @ObservationIgnored private let system: PermissionSystem
    public private(set) var microphone: PermissionStatus
    public private(set) var microphonePresent: Bool
    /// Requests made through `request(_:)` (the test hook for "no prompt before a click / during onboarding").
    public private(set) var requestCount = 0
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    public init(system: PermissionSystem, observeActivation: Bool = true) {
        self.system = system
        microphone = PermissionStatus(system.microphoneStatus())
        microphonePresent = system.hasMicrophone()
        if observeActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    public func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .microphone: microphone
        case .accessibility: system.accessibilityTrusted() ? .granted : .notDetermined
        case .screenRecording: system.screenRecordingGranted() ? .granted : .notDetermined
        case .notifications: .notDetermined  // M8.T08 reads UNUserNotificationCenter asynchronously
        }
    }

    /// The microphone button's state. A missing device wins over the permission state (nothing to grant for).
    public var micAvailability: MicAvailability {
        if !microphonePresent { return .noDevice }
        switch microphone {
        case .granted: return .ready
        case .notDetermined: return .needsPermission
        case .denied, .restricted: return .denied
        }
    }

    /// Asks macOS (the system dialog appears only from `.notDetermined`). Call only from a user action.
    @discardableResult
    public func request(_ kind: PermissionKind) async -> Bool {
        guard kind == .microphone else { return status(kind) == .granted }
        requestCount += 1
        PermissionCoordinator.shared.recordRequested(.microphone)  // M8.T14: the R-109 step log
        if microphone == .notDetermined { _ = await system.requestMicrophone() }
        refresh()
        return microphone == .granted
    }

    public func openSystemSettings(_ kind: PermissionKind) { system.open(Self.settingsURL(kind)) }

    /// Re-reads the status (app activation, device change).
    public func refresh() {
        let m = PermissionStatus(system.microphoneStatus())
        if m != microphone { microphone = m }
        let p = system.hasMicrophone()
        if p != microphonePresent { microphonePresent = p }
    }

    static func systemFromLaunchOptions() -> PermissionSystem {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let s = LaunchOptions.current.fakePermissions["microphone"], let state = PermissionStatus(rawValue: s) {
            return .fake(microphone: state)
        }
        #endif
        return .live
    }
}
