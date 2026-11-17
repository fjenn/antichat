// The Video pack's runtime (`video-runtime`: CPython + MLX + FastVideo, catalog/runtimes.yaml) is part of the pack:
// text-to-video cannot run without it, so the pack is not "Ready" until it is on disk in the catalog's version.
// Nobody installs it by hand:
//   * turning the pack on fetches it with the models (PackManagementModel.enable);
//   * at launch, and when the catalog arrives, a pack that is on with a missing or older runtime fetches it quietly;
//   * a chat that asks for a video before it is there waits for it (InstalledVideoModels.request).
// Earlier try-out builds carried the zip inside the app, which hid that the release build never fetched it: the row
// said Ready and `create_video` answered `unavailable`.
import AntiChatFoundation
import AntiChatHarness
import AntiChatNetwork
import AntiChatPlatform
import AntiChatStorage
import Foundation
import Observation

@MainActor @Observable
final class VideoRuntimeInstall {
    static let shared = VideoRuntimeInstall()
    static let name = "video-runtime"

    /// What the pack row needs to know about the runtime (pure input of `PackRowState.withRuntime`).
    enum Facts: Equatable, Sendable {
        /// Installed in the catalog's version, or the catalog lists none (nothing to wait for).
        case ready
        case missing(sizeBytes: Int64)
        case installing(done: Int64, total: Int64)
        case failed
    }

    /// Bytes received while an install runs (nil = none running).
    private(set) var progress: Int64?
    private(set) var failed = false
    /// Bumped after every install / refresh so observers of `facts` re-read the disk.
    private(set) var revision = 0
    @ObservationIgnored var database: AppDatabase?
    @ObservationIgnored var catalogRuntime: () -> CatalogRuntime? = {
        let store = CatalogLaunch.shared
        return store?.catalog?.runtime(VideoRuntimeInstall.name)
            ?? store?.snapshot.verifiedData.flatMap { try? ModelCatalog.decode($0).runtime(VideoRuntimeInstall.name) }
    }
    @ObservationIgnored var mayInstallNew: () -> Bool = { CatalogLaunch.shared?.mayInstallNew == true }
    @ObservationIgnored var makeInstaller: (AppDatabase) -> RuntimeInstaller = { RuntimeInstaller(registry: RuntimeRegistry(database: $0)) }
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var attempts = 0

    var facts: Facts {
        _ = revision
        guard let runtime = catalogRuntime(), let database else { return .ready }
        if makeInstaller(database).isCurrent(runtime) { return .ready }
        if let progress { return .installing(done: progress, total: runtime.sizeBytes) }
        return failed ? .failed : .missing(sizeBytes: runtime.sizeBytes)
    }

    var isReady: Bool { facts == .ready }

    /// The installed runtime folder in the catalog's version (nil = not there yet).
    var currentDir: URL? {
        guard let runtime = catalogRuntime(), let database else { return nil }
        let installer = makeInstaller(database)
        return installer.isCurrent(runtime) ? installer.installed(runtime.name)?.url : nil
    }

    /// Starts the install when it is missing (no-op while one runs or when it is current).
    func install() {
        guard let database, let runtime = catalogRuntime(), progress == nil else { return }
        let installer = makeInstaller(database)
        guard !installer.isCurrent(runtime) else { return }
        guard mayInstallNew() else { failed = true; return }  // fail closed, as models do
        failed = false
        progress = 0
        Task {
            do {
                _ = try await installer.install(runtime) { bytes in
                    Task { @MainActor in if self.progress != nil { self.progress = bytes } }
                }
            } catch {
                failed = true
                AppLog.log(.download, .error, "runtime: \(runtime.folderName) did not install (\(error))")
            }
            progress = nil
            revision += 1
        }
    }

    /// The install as something to await (a chat's `create_video` before the runtime is there).
    func ensure() async -> Bool {
        if isReady { return true }
        guard !NetworkPolicyStore.shared.offlineOnly else { return false }
        install()
        while progress != nil { try? await Task.sleep(for: .milliseconds(200)) }
        return isReady
    }

    // MARK: Launch

    /// At launch and whenever the catalog / network changes: the Video pack is on and its runtime is missing or older
    /// than the catalog's ⇒ fetch it quietly (a few tries per launch; a failure shows on the pack row with Retry).
    func start(database: AppDatabase) {
        guard self.database == nil, !database.isInMemory, !UserDefaults.antichatIsIsolated else { return }
        self.database = database
        for name in [CatalogStore.didChange, NetworkPolicyStore.didChange, PathStatus.didChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.kick() }
            })
        }
        kick()
    }

    func kick() {
        revision += 1
        guard attempts < 3, !OnboardingGate.shouldShow(), !NetworkPolicyStore.shared.offlineOnly,
              PackManagementModel.shared.enabled.contains(.video), !isReady, progress == nil, mayInstallNew() else { return }
        attempts += 1
        install()
    }
}

extension PackRowState {
    /// The Video pack's row with its runtime counted in: Ready (or Update available) only when the runtime is on disk
    /// too. While the models still download the row shows them; once they are here it shows the runtime's own fetch.
    func withRuntime(_ runtime: VideoRuntimeInstall.Facts) -> PackRowState {
        switch self {
        case .ready, .updateAvailable: break
        default: return self
        }
        switch runtime {
        case .ready: return self
        case .missing(let size): return .notDownloaded(downloadBytes: size, queued: false)
        case .installing(let done, let total):
            let percent = total > 0 ? min(99, Int(Double(done) / Double(total) * 100)) : 0
            return .downloading(percent: percent, paused: false, done: min(done, total), total: total)
        case .failed: return .failed
        }
    }
}
