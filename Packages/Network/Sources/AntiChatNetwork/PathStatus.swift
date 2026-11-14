// M2.T03 step 2 (R-209 AC4; P-platform-08): is there a route to the internet? NWPathMonitor wrapper that feeds the
// sidebar NetworkIndicator ("Offline" when unsatisfied) and download pausing (T09). `-FakeNetwork
// none|expensive|constrained|ok` (DEBUG) replaces the monitor with a fixed state.
import Foundation
import Network
import AntiChatFoundation

public final class PathStatus: @unchecked Sendable {
    public enum State: String, Sendable, Equatable { case ok, expensive, constrained, none }

    public static let shared = PathStatus(fake: LaunchOptions.current.fakeNetwork)
    /// Posted (object = the PathStatus) whenever `state` changes.
    public static let didChange = Notification.Name("AntiChatPathStatusDidChange")

    private let lock = NSLock()
    private var _state: State
    private let monitor: NWPathMonitor?

    /// `fake` = a `-FakeNetwork` value; nil = the live monitor.
    public init(fake: String?) {
        if let fake, let s = State(rawValue: fake) {
            _state = s
            monitor = nil
        } else {
            _state = .ok
            let m = NWPathMonitor()
            monitor = m
            m.pathUpdateHandler = { [weak self] path in self?.update(Self.state(of: path)) }
            m.start(queue: DispatchQueue(label: "app.antichat.pathstatus"))
        }
    }

    deinit { monitor?.cancel() }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    /// No route at all (the sidebar shows `net.offline`).
    public var isOffline: Bool { state == .none }

    static func state(of path: NWPath) -> State {
        guard path.status == .satisfied else { return .none }
        if path.isConstrained { return .constrained }
        if path.isExpensive { return .expensive }
        return .ok
    }

    func update(_ s: State) {
        lock.lock()
        let changed = s != _state
        _state = s
        lock.unlock()
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}
