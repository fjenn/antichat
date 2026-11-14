// M4.T04 step 6 (R-291, NFR-VID3): quitting while a picture or video is being made asks first —
// `job.quit.title` / `job.quit.body`, [Keep making it] (default) and [Quit anyway] (cancels the job, its row reads
// `cancelled`, then quits). Closing a window never stops a job (the queue lives in the app, not the window).
// M8.T12 step 8 (R-042 AC3): while a **video** is queued or being made the question is cancel-or-wait —
// `quit.jobRunning.title` / `.body`, [Wait] (default: AntiChat quits by itself once the jobs are done, `quit.waiting`
// toast) and [Cancel video and quit].
// The app delegate calls this before the incognito quit guard.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AppKit

@MainActor
public enum MediaJobQuitGuard {
    public enum Choice: Sendable { case keepMaking, quitAnyway, wait }

    /// Test hook: answers instead of the modal alert (nil = show it).
    public static var scriptedChoice: Choice?
    /// The last alert's kind (probe): "video" or "picture".
    public private(set) static var lastAsked: String?
    /// A Wait is holding the quit (probe).
    public private(set) static var waiting = false

    /// `next` = the reply of the guards after this one (incognito).
    public static func reply(_ sender: NSApplication, queue: MediaJobQueue? = MediaJobQueue.shared,
                             next: @escaping @MainActor () -> NSApplication.TerminateReply) -> NSApplication.TerminateReply {
        guard let queue, queue.hasRunning || !AppNotifications.activeJobs.isEmpty else { return next() }
        let video = AppNotifications.hasActiveVideo
        let choice = video ? askVideo() : ask()
        switch choice {
        case .keepMaking:
            return .terminateCancel
        case .wait:
            waiting = true
            AppToasts.shared.show(Toast(.info, CopyText(CopyKey("quit.waiting")), persistent: true))
            Task { @MainActor in
                await waitUntilIdle(queue)
                waiting = false
                AppToasts.shared.current = nil
                answer(sender, next())
            }
            return .terminateLater
        case .quitAnyway:
            Task { @MainActor in
                do { try await queue.cancelForQuit() } catch { AppLog.log(.ui, .error, "quit: cancel media jobs: \(error)") }
                answer(sender, next())
            }
            return .terminateLater
        }
    }

    static func answer(_ sender: NSApplication, _ reply: NSApplication.TerminateReply) {
        switch reply {
        case .terminateNow: sender.reply(toApplicationShouldTerminate: true)
        case .terminateCancel: sender.reply(toApplicationShouldTerminate: false)
        case .terminateLater: break  // the next guard replies itself
        @unknown default: sender.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Returns once no picture or video is queued or running (the job's own notification has been posted by then).
    static func waitUntilIdle(_ queue: MediaJobQueue) async {
        func idle() -> Bool { !queue.hasRunning && AppNotifications.activeJobs.isEmpty }
        while !idle() {
            let token = UUID()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                AppNotifications.jobsChanged[token] = {
                    AppNotifications.jobsChanged[token] = nil  // one-shot; other subscribers stay
                    c.resume()
                }
            }
        }
    }

    /// M5.T11 (NFR-VID3, R-040 AC2): closing the last window never ends a running video job — the app stays open
    /// while one runs (the helper owns the job; reopening a window re-attaches its card). Otherwise the menu bar
    /// item decides, as before.
    public static func terminateAfterLastWindowClosed(menuBarItem: Bool, queue: MediaJobQueue? = MediaJobQueue.shared) -> Bool {
        if queue?.hasRunningVideo == true { return false }
        return !menuBarItem
    }

    static func ask() -> Choice {
        lastAsked = "picture"
        if let scriptedChoice { return scriptedChoice == .wait ? .keepMaking : scriptedChoice }
        let alert = NSAlert()
        alert.messageText = CopyKey("job.quit.title").string()
        alert.informativeText = CopyKey("job.quit.body").string()
        alert.addButton(withTitle: CopyKey("job.quit.cancel").string())  // default (Return)
        alert.addButton(withTitle: CopyKey("job.quit.confirm").string())
        return alert.runModal() == .alertSecondButtonReturn ? .quitAnyway : .keepMaking
    }

    /// R-042 AC3: cancel or wait.
    static func askVideo() -> Choice {
        lastAsked = "video"
        if let scriptedChoice { return scriptedChoice == .keepMaking ? .wait : scriptedChoice }
        let alert = NSAlert()
        alert.messageText = CopyKey("quit.jobRunning.title").string()
        alert.informativeText = CopyKey("quit.jobRunning.body").string()
        alert.addButton(withTitle: CopyKey("quit.wait").string())  // default (Return)
        alert.addButton(withTitle: CopyKey("quit.cancelVideo").string())
        return alert.runModal() == .alertSecondButtonReturn ? .quitAnyway : .wait
    }
}
