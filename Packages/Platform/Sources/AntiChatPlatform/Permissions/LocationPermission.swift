// M8.T08 step 4 (R-091 AC3, R-109; G-065; P-shell-20): Location, just in time. AntiChat never asks for Location at
// launch or during onboarding; only turning on Settings › Tools & Connections › Web search › "Use my approximate
// location for search" shows the in-app explainer (`perm.location.why`) and then the When-In-Use request
// (M8.T14: the API call itself lives in PermissionCoordinator, the app's only request site).
// A denial (or Location Services off system-wide) has a recovery action: [Open System Settings].
//
// The CoreLocation side follows the vendored Osaurus `SystemPermissionService` location case
// (Vendor/osaurus@66c3dde/Packages/OsaurusCore/Services/SystemPermissionService.swift: lazy `CLLocationManager`
// because its init is a synchronous locationd handshake; status from the delegate's
// `locationManagerDidChangeAuthorization`). That case was never trimmed by UP-OS-018, so nothing is re-enabled
// in the vendored file; AntiChat asks for When-In-Use (Osaurus asks for Always).
// The system calls are injected so tests and `-FakePermission location=<state>` never touch the TCC database.
import AntiChatFoundation
import AppKit
@preconcurrency import CoreLocation
import Foundation
import Observation

public enum LocationAuthorization: String, Sendable, Equatable {
    case notDetermined, granted, denied, restricted
    /// Location Services are off for the whole Mac (System Settings › Privacy & Security › Location Services).
    case servicesOff

    public init(_ status: CLAuthorizationStatus, servicesEnabled: Bool) {
        guard servicesEnabled else { self = .servicesOff; return }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse: self = .granted
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }

    /// The user must change it in System Settings (the system dialog will not appear again).
    public var needsSystemSettings: Bool { self == .denied || self == .restricted || self == .servicesOff }
}

/// The CoreLocation calls LocationPermission makes; replaced in tests and by `-FakePermission location=<state>`.
public struct LocationSystem: Sendable {
    public var status: @Sendable () -> LocationAuthorization
    /// Shows the macOS dialog when the status is `.notDetermined`; the answer arrives through `onChange`.
    public var request: @Sendable () -> Void
    public var open: @Sendable (URL) -> Void

    public init(status: @escaping @Sendable () -> LocationAuthorization, request: @escaping @Sendable () -> Void,
                open: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.status = status
        self.request = request
        self.open = open
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// A fixed state (`-FakePermission location=…`, tests); `request` moves `.notDetermined` to `answer` (nil = the dialog stays unanswered).
    public static func fake(_ state: LocationAuthorization, answer: LocationAuthorization? = nil,
                            opened: (@Sendable (URL) -> Void)? = nil) -> LocationSystem {
        let box = Box(state)
        return LocationSystem(status: { box.value },
                              request: { if box.value == .notDetermined, let answer { box.value = answer } },
                              open: opened ?? { _ in })
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var v: LocationAuthorization
        init(_ v: LocationAuthorization) { self.v = v }
        var value: LocationAuthorization {
            get { lock.withLock { v } }
            set { lock.withLock { v = newValue } }
        }
    }
    #endif
}

@MainActor @Observable
public final class LocationPermission {
    public static let shared = LocationPermission(system: LocationPermission.systemFromLaunchOptions())

    /// System Settings › Privacy & Security › Location Services.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!

    @ObservationIgnored private let system: LocationSystem
    public private(set) var status: LocationAuthorization
    /// Requests made through `request()` (the test hook for "never asked before the user turns the setting on").
    public private(set) var requestCount = 0
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    public init(system: LocationSystem, observeActivation: Bool = true) {
        self.system = system
        status = system.status()
        if observeActivation {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    /// Asks macOS (the dialog appears only from `.notDetermined`). Call only from the user turning the setting on,
    /// after the explainer.
    public func request() {
        requestCount += 1
        PermissionCoordinator.shared.recordRequested(.location)  // M8.T14: the R-109 step log
        if status == .notDetermined { system.request() }
        refresh()
    }

    public func openSystemSettings() { system.open(Self.settingsURL) }

    public func refresh() {
        let s = system.status()
        if s != status { status = s }
    }

    /// The status read off the main actor, from the same source as `shared` (the search region hint asks per search;
    /// R-091 AC3). Reads only, never prompts.
    public nonisolated static func currentStatus() -> LocationAuthorization { systemFromLaunchOptions().status() }

    nonisolated static func systemFromLaunchOptions() -> LocationSystem {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let s = LaunchOptions.current.fakePermissions["location"], let state = LocationAuthorization(rawValue: s) {
            return .fake(state)
        }
        #endif
        return .live
    }
}

extension LocationSystem {
    /// CoreLocation. The manager is built on first use (never at launch): reading the status of a fresh manager
    /// does not prompt, and only `request` can show the dialog.
    public static let live: LocationSystem = {
        let bridge = LiveLocationBridge()
        return LocationSystem(
            status: { bridge.status() },
            request: { bridge.request() },
            open: { url in Task { @MainActor in NSWorkspace.shared.open(url) } })
    }()
}

/// Owns the lazily created `CLLocationManager` on the main thread and forwards authorization changes.
private final class LiveLocationBridge: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private var manager: CLLocationManager?

    private func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private func ensure() -> CLLocationManager {
        if let manager { return manager }
        let m = CLLocationManager()
        m.delegate = self
        manager = m
        return m
    }

    func status() -> LocationAuthorization {
        onMain {
            // Before the user ever turned the setting on, no manager exists; a never-asked app is `.notDetermined`.
            let enabled = CLLocationManager.locationServicesEnabled()
            return LocationAuthorization(ensure().authorizationStatus, servicesEnabled: enabled)
        }
    }

    func request() { onMain { PermissionCoordinator.requestWhenInUse(ensure()) } }  // M8.T14: the one request site

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in LocationPermission.shared.refresh() }
    }
}
