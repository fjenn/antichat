// M10.T03 (R-219, NFR-PR5; P-platform-12): Sparkle app updates. Ported from osaurus@2922745
// Packages/OsaurusCore/Services/UpdaterService.swift (MIT; allow-list row `watch`, A-M10-T03a): the
// SPUStandardUpdaterController ownership, the beta-channel switch and the "wait for the in-flight background session
// before a user check" loop are kept; the Osaurus feed, NSLog verbosity and ObservableObject are replaced by
// `UpdaterBridge` (feed from Endpoints.plist, NetworkGate `updates` + Offline only, network_activity rows,
// "Restart to update" instead of Sparkle's window) and the @Observable `UpdateState`.
//
// Lifecycle: `start()` after the main window's first paint (never before, NFR-U1); Release builds only — Debug,
// probe, XCTest and dev-container launches never create an updater (no network from tests).
import AntiChatFoundation
import AntiChatNetwork
import Foundation
import Sparkle

@MainActor
public final class UpdaterService {
    public static let shared = UpdaterService()

    public let state: UpdateState
    public let bridge: UpdaterBridge
    private let feed: UpdateFeed
    private var controller: SPUStandardUpdaterController?

    public init(state: UpdateState = UpdateState(), policy: NetworkPolicyStore = .shared,
                feed: UpdateFeed = .current()) {
        self.state = state
        self.feed = feed
        self.bridge = UpdaterBridge(state: state, policy: policy, feed: feed)
    }

    public var isStarted: Bool { controller != nil }
    /// VQ (S-21 Updates): when Sparkle last looked for an update (its own record, also when the updater is not
    /// running in this process; read via `AppDefaults.standard`: the app domain Sparkle writes, private in a test
    /// process); nil = never.
    public var lastCheckDate: Date? {
        updater?.lastUpdateCheckDate ?? (AppDefaults.standard.object(forKey: "SULastCheckTime") as? Date)
    }
    var updater: SPUUpdater? { controller?.updater }

    /// Creates and starts Sparkle (idempotent). RC review P2-8: never without a feed — a Developer ID build that
    /// carries the committed test key resolves to none, so Sparkle never trusts that key.
    public func start() {
        guard controller == nil else { return }
        guard !feed.isDisabled else {
            AppLog.log(.update, .error, "updates off: no feed for this build's SUPublicEDKey")
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: bridge, userDriverDelegate: bridge)
        controller = c
        do { try c.updater.start() } catch {
            state.phase = .failed(error.localizedDescription)
            AppLog.log(.update, .error, "Sparkle failed to start: \(error.localizedDescription)")
        }
        state.automaticallyChecks = c.updater.automaticallyChecksForUpdates
        state.automaticallyDownloads = c.updater.automaticallyDownloadsUpdates
    }

    // MARK: Settings › Updates

    public func setAutomaticallyChecks(_ on: Bool) {
        updater?.automaticallyChecksForUpdates = on
        state.automaticallyChecks = on
    }

    public func setAutomaticallyDownloads(_ on: Bool) {
        updater?.automaticallyDownloadsUpdates = on
        state.automaticallyDownloads = on
    }

    public func setBeta(_ on: Bool) {
        UpdateFeed.betaEnabled = on
        state.beta = on
        updater?.resetUpdateCycle()
    }

    /// [Check now]. A background session in flight makes `canCheckForUpdates` false and Sparkle drops the user
    /// check; wait up to 5 s for it to settle (osaurus `checkForUpdates`).
    public func checkNow() {
        guard let c = controller else { start(); controller?.updater.checkForUpdatesInBackground(); return }
        state.phase = .checking
        if c.updater.canCheckForUpdates { c.updater.checkForUpdatesInBackground(); return }
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if let u = self?.controller?.updater, u.canCheckForUpdates { u.checkForUpdatesInBackground(); return }
            }
        }
    }

    /// The pill's action. [Restart to update]: run Sparkle's stored install block (installs and relaunches).
    /// fix/review P1: [Download and install] (not downloaded yet, automatic downloads off): a user-initiated check,
    /// which brings up Sparkle's window for the pending update (download, then install and relaunch).
    public func restartToUpdate() {
        bridge.installOrDownload { [weak self] in
            guard let self else { return }
            if controller == nil { start() }
            controller?.checkForUpdates(nil)
        }
    }
}

