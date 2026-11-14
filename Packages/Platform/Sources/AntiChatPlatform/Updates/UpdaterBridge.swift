// M10.T03 steps 2–3, 5, 9 (R-219 AC1–AC4, R-209, NFR-PR5; P-platform-12): Sparkle's delegate pair.
//  - feed: `UpdateFeed` (Endpoints.plist; override only in dev-keys builds); channels: beta toggle;
//  - every check asks NetworkGate (`updates` on, Offline only off) through `UpdateGateDelegate` and is logged as a
//    `network_activity` row (category updates; blocked checks too);
//  - "Restart to update": with SUAutomaticallyUpdate Sparkle downloads silently and offers the install-on-quit
//    block; we keep it, set `UpdateState.ready` (pill + notes sheet) and run it on [Restart to update];
//  - gentle reminders: a scheduled update found while the app is active never pops Sparkle's window; it becomes
//    the pill (the standard UI still handles user-initiated checks while automatic download is off). fix/review P1:
//    such an update is not downloaded and Sparkle gives no install block, so the pill is `UpdateState.available`
//    ([Download and install]: `installOrDownload` hands it to Sparkle's window, which downloads, then installs and
//    relaunches), never a "Restart to update" that does nothing;
//  - a failed or improperly signed update leaves the running version alone and shows `update.failed`.
import AntiChatNetwork
import Foundation
import Sparkle

public final class UpdaterBridge: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate, @unchecked Sendable {
    private let gate: UpdateGateDelegate
    private let policy: NetworkPolicyStore
    private let feed: UpdateFeed
    @MainActor private let state: UpdateState
    @MainActor private var installBlock: (() -> Void)?

    @MainActor
    public init(state: UpdateState, policy: NetworkPolicyStore = .shared, feed: UpdateFeed) {
        self.state = state
        self.policy = policy
        self.feed = feed
        self.gate = UpdateGateDelegate(policy: policy)
    }

    // MARK: SPUUpdaterDelegate — feed, channels, gate

    public func feedURLString(for updater: SPUUpdater) -> String? { feed.url.isEmpty ? nil : feed.url }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateFeed.betaEnabled ? ["beta"] : []
    }

    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        do { try gate.updater(updater, mayPerform: updateCheck) } catch {
            record(.blocked)
            throw error
        }
        Task { @MainActor in if case .failed = self.state.phase { self.state.phase = .checking } }
    }

    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                        updateCheck: SPUUpdateCheck) throws {
        try gate.updater(updater, shouldProceedWithUpdate: updateItem, updateCheck: updateCheck)
    }

    public func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        gate.updater(updater, shouldDownloadReleaseNotesForUpdate: updateItem)
    }

    public func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) { record(.ok) }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in if self.state.phase == .checking { self.state.phase = .idle } }
    }

    public func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let e = error as NSError
        // "No update found" arrives here too (SUNoUpdateError); it is not a failure.
        if e.domain == SUSparkleErrorDomain, e.code == Int(SUError.noUpdateError.rawValue) { return }
        record(.failed)
        Task { @MainActor in self.state.phase = .failed(e.localizedDescription) }
    }

    /// AC4: install on quit, or now via [Restart to update].
    public func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                        immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        let notes = item.itemDescription
        Task { @MainActor in
            self.installBlock = immediateInstallationBlock
            self.state.phase = .ready(version: version, notesHTML: notes)
        }
        return true
    }

    @MainActor
    func installNow() {
        guard let block = installBlock else { return }
        installBlock = nil
        block()
    }

    /// The pill's primary action. Downloaded (Sparkle gave its install block): install and relaunch now. Not
    /// downloaded (a gentle reminder with automatic downloads off): `download`, i.e. a user-initiated check, which
    /// resumes the pending update in Sparkle's window (download, then install and relaunch).
    @MainActor
    func installOrDownload(download: () -> Void) {
        if installBlock != nil { installNow(); return }
        guard state.showsPill else { return }
        download()
    }

    @MainActor var hasInstallBlock: Bool { installBlock != nil }

    // MARK: SPUStandardUserDriverDelegate — gentle reminders

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                    andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Never pop Sparkle's window for a scheduled update while the app is in use; the pill takes over.
        !immediateFocus
    }

    public func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                          state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        showGentleReminder(update)
    }

    /// A scheduled update Sparkle did not show becomes the pill: "Restart to update" only once Sparkle has handed
    /// over its install block (downloaded); otherwise [Download and install] (`UpdateState.available`).
    func showGentleReminder(_ update: SUAppcastItem) {
        let version = update.displayVersionString
        let notes = update.itemDescription
        Task { @MainActor in
            if case .ready = self.state.phase { return }
            self.state.phase = self.installBlock != nil
                ? .ready(version: version, notesHTML: notes)
                : .available(version: version, notesHTML: notes)
        }
    }

    // MARK: network_activity (R-297): one row per appcast check

    private func record(_ outcome: NetworkEvent.Outcome) {
        let host = URL(string: feed.url)?.host ?? "appcast"
        NetworkGate.activitySink?(NetworkEvent(category: .updates, host: host, bytes: 0, outcome: outcome, incognito: false))
    }
}
