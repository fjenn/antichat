// M2.T14 step 1, app side (R-206 AC3, R-207 AC4). The app process watches memory pressure too
// (`DispatchSource.makeMemoryPressureSource([.warning, .critical])`): WARNING drops the app's own caches through the
// registered trimmers; CRITICAL also tells the observers (the job card shows `sched.pausedLowMemory` [Resume] when the
// helper paused the job). The helper's PressureMonitor does the model releases; the app is never killed and has no
// forced-exit path. `-FakePressure warn|critical` (Debug) is sent to the helper with the first SetPolicy instead.
import AntiChatFoundation
import Foundation

public final class AppPressureMonitor: @unchecked Sendable {
    public static let shared = AppPressureMonitor()
    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var trimmers: [@Sendable () -> Void] = []
    private var observers: [@Sendable (PressureLevel) -> Void] = []
    public private(set) var level: PressureLevel = .normal

    public init() {}

    public func start() {
        lock.withLock {
            guard source == nil else { return }
            let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .global(qos: .utility))
            s.setEventHandler { [weak self] in
                let ev = s.data
                self?.handle(ev.contains(.critical) ? .critical : ev.contains(.warning) ? .warning : .normal)
            }
            s.resume()
            source = s
        }
    }

    public func addTrimmer(_ f: @escaping @Sendable () -> Void) { lock.withLock { trimmers.append(f) } }
    public func observe(_ f: @escaping @Sendable (PressureLevel) -> Void) { lock.withLock { observers.append(f) } }

    public func handle(_ l: PressureLevel) {
        let (t, o) = lock.withLock { () -> ([@Sendable () -> Void], [@Sendable (PressureLevel) -> Void]) in
            level = l
            return (trimmers, observers)
        }
        if l > .normal { t.forEach { $0() } }
        o.forEach { $0(l) }
        AppLog.log(.ui, l == .critical ? .error : .info, "app memory pressure: \(l)")
    }
}
