// M2.T09 step 4 (R-204 AC3): after sleep, and when the network path comes back, system-paused downloads resume.
// Sources: `NSWorkspace.didWakeNotification` (on NSWorkspace's own center) and `PathStatus.didChange`.
import AntiChatNetwork
import AppKit
import Foundation

public final class WakeObserver: @unchecked Sendable {
    public enum Event: Sendable, Equatable { case didWake, pathChanged(PathStatus.State) }

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(path: PathStatus = .shared, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
                center: NotificationCenter = .default, handler: @escaping @Sendable (Event) -> Void) {
        tokens.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            handler(.didWake)
        }))
        tokens.append((center, center.addObserver(forName: PathStatus.didChange, object: path, queue: nil) { [weak path] _ in
            if let path { handler(.pathChanged(path.state)) }
        }))
    }

    deinit { for (c, t) in tokens { c.removeObserver(t) } }
}
