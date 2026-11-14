// M8.T01 (R-301 AC3; S-25 "Migration from a newer version"): the blocking window the app shows instead of the main
// window when its database was migrated by a newer AntiChat. No sidebar, no chats; the data is not touched.
// [Update AntiChat] runs the updater when one is wired (`LaunchBlockedActions.checkForUpdates`), else opens
// `Endpoints.plist` `DownloadURL`.
import AntiChatDesign
import AntiChatPlatform
import AntiChatStorage
import AntiChatPlatform
import AppKit
import SwiftUI

/// What the blocking windows can do (the app fills these; tests inspect them).
@MainActor
public struct LaunchBlockedActions {
    public var checkForUpdates: (@MainActor () -> Void)?
    public var openDownloadPage: @MainActor () -> Void
    public var relaunch: @MainActor () -> Void
    public var quit: @MainActor () -> Void
    /// M8.T09 "Report a problem" with the error code prefilled; nil hides the button until T09 lands.
    public var reportProblem: (@MainActor (String) -> Void)?

    public init(checkForUpdates: (@MainActor () -> Void)? = nil,
                openDownloadPage: @escaping @MainActor () -> Void = { LaunchBlockedActions.openDownloadURL() },
                relaunch: @escaping @MainActor () -> Void = { AppRelaunch.relaunch() },
                quit: @escaping @MainActor () -> Void = { NSApp.terminate(nil) },
                reportProblem: (@MainActor (String) -> Void)? = nil) {
        self.checkForUpdates = checkForUpdates
        self.openDownloadPage = openDownloadPage
        self.relaunch = relaunch
        self.quit = quit
        self.reportProblem = reportProblem
    }

    /// `Endpoints.plist` `DownloadURL` in the app bundle (dev: the local site's /download).
    public static func downloadURL(bundle: Bundle = .main) -> URL {
        if let u = Endpoints.url("DownloadURL", bundle: bundle) { return u }  // M10: Debug → DownloadURLDev
        return URL(string: "http://localhost:4321/download")!
    }

    @MainActor public static func openDownloadURL() { NSWorkspace.shared.open(downloadURL()) }
}

/// The root view for a blocked launch: one of the S-25 windows.
public struct LaunchBlockedView: View {
    let state: AppLaunchState
    let databaseURL: URL
    let actions: LaunchBlockedActions

    public init(state: AppLaunchState, databaseURL: URL, actions: LaunchBlockedActions = LaunchBlockedActions()) {
        self.state = state
        self.databaseURL = databaseURL
        self.actions = actions
    }

    public var body: some View {
        switch state {
        case .ready: EmptyView()
        case .newerData: NewerDataWindow(actions: actions)
        case .migrationFailed(let code, _): MigrationFailedWindow(code: code, databaseURL: databaseURL, actions: actions)
        case .backupNoSpace(let need): BackupNoSpaceWindow(neededBytes: need, actions: actions)
        }
    }
}

struct NewerDataWindow: View {
    let actions: LaunchBlockedActions

    var body: some View {
        BlockingPanel(symbol: "arrow.up.circle", message: CopyText(CopyKey("storage.newerVersion"))) {
            Button(action: { actions.quit() }) { Text(CopyKey("storage.quit.cta")) }
                .probeID("newerData.quit")
            Button(action: { (actions.checkForUpdates ?? actions.openDownloadPage)() }) { Text(CopyKey("storage.update.cta")) }
                .keyboardShortcut(.defaultAction)
                .probeID("newerData.update")
        }
        // Q-015 r4: a container, so its children keep their own identifiers. Without it the window's id replaced the
        // message's and both buttons' (`blocking.message`, `newerData.quit` / `.update` were never found).
        .accessibilityElement(children: .contain)
        .probeID("newerData.window")
    }
}

/// Icon, one message, a row of buttons; the shared layout of the S-25 blocking windows.
struct BlockingPanel<Buttons: View>: View {
    let symbol: String
    let message: CopyText
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: Spacing.space5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(message)
                .typeStyle(.title3)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .probeID("blocking.message")
            HStack(spacing: Spacing.space3) { buttons() }
        }
        .padding(Spacing.space8)
        .frame(width: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfaceCanvas)
    }
}

/// Relaunch: a new instance of this bundle, then terminate (restore from backup, try again, Remove everything).
/// Review fix (M8.T16): the new instance waits for this process to exit before it opens anything (a staged restore
/// swaps the database triple, and two processes must never share the container); this quit skips the quit guards
/// (the relaunch is the app's own action); after Remove everything the new instance sweeps what the old one wrote
/// while it quit (saved state, preferences) before it starts.
public enum AppRelaunch {
    static let afterPIDFlag = "-RelaunchAfterPID", sweepFlag = "-RelaunchSweepData"
    /// A relaunch is quitting this process: the app delegate answers `.terminateNow` (no job / incognito prompt).
    @MainActor public private(set) static var inProgress = false

    @MainActor public static func relaunch(sweepData: Bool = false) {
        inProgress = true
        var args: [String] = []
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            if a == afterPIDFlag || a == sweepFlag { _ = it.next(); continue }  // never forward an earlier relaunch's flags
            args.append(a)
        }
        args += [afterPIDFlag, "\(getpid())"] + (sweepData ? [sweepFlag, "YES"] : [])
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = args
        // Isolation audit: NSWorkspace calls this on a private queue; a closure written here would be main-actor
        // isolated and trap Swift 6's isolation check (the P74 crash class). Nonisolated, it hops to the main actor.
        let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = WorkspaceCompletion.onMain { _ in
            NSApp.terminate(nil)
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config, completionHandler: done)
    }

    /// The first thing a relaunched instance does (before the database or any window): wait (≤ 60 s) until the
    /// previous process has exited, then, after Remove everything, delete the documented data paths again.
    public static func waitForPredecessorIfRelaunched(arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: afterPIDFlag), i + 1 < arguments.count, let pid = pid_t(arguments[i + 1]),
              pid > 0, pid != getpid() else { return }
        let deadline = Date().addingTimeInterval(60)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
        guard let j = arguments.firstIndex(of: sweepFlag), j + 1 < arguments.count, arguments[j + 1] == "YES" else { return }
        let paths = DataPaths.current()
        let svc = RemoveEverythingService(paths: paths)
        for url in svc.plan() { try? FileManager.default.removeItem(at: url) }
        UserDefaults.standard.removePersistentDomain(forName: paths.bundleID)
    }
}
