// M2.T14 steps 2–3 (R-207 AC1–AC3, NFR-M2, NFR-B2, NFR-B3), app side. Watches the power source (AC / battery % / Low
// Power Mode: `IOPSNotificationCreateRunLoopSource`, `NSProcessInfoPowerStateDidChange`) and the thermal state
// (`ProcessInfo.thermalStateDidChangeNotification`), or their Debug fakes (`-FakePower`, `-FakeThermal`), and
// computes the PowerPolicy mode in effect for the `set.performance` setting. Event-driven: no polling timer (NFR-B1).
// Observers (the composition root) push the result to the helper through SetPolicy and show the one-line notices
// (`power.saver.on`, `power.cooler`). PowerSource itself lives with the download policy (M2.T09).
import AntiChatFoundation
import Foundation
import IOKit.ps

public final class PowerMonitor: @unchecked Sendable {
    public struct State: Sendable, Equatable {
        public var source: PowerSource
        public var mode: PerformanceMode
        public var effective: PerformanceMode
        public var thermal: ThermalPolicy.State
        public var effects: PowerPolicy.Effects { PowerPolicy.effects(effective) }
        /// The notices to show now ("never silently degrade").
        public var notices: [String] {
            var n: [String] = []
            if effective == .batterySaver { n.append("power.saver.on") }
            if let t = ThermalPolicy.notice(thermal) { n.append(t) }
            return n
        }
    }

    public static let shared = PowerMonitor()

    private let lock = NSLock()
    private var observers: [UUID: @Sendable (State) -> Void] = [:]
    private var tokens: [NSObjectProtocol] = []
    private var runLoopSource: CFRunLoopSource?
    private var modeProvider: @Sendable () -> PerformanceMode = { .auto }
    private var last: State?
    private let options: LaunchOptions

    public init(options: LaunchOptions = .current) { self.options = options }

    public static func thermal(options: LaunchOptions = .current) -> ThermalPolicy.State {
        if let f = options.fakeThermal, let s = ThermalPolicy.State(rawValue: f) { return s }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    public func state() -> State {
        let src = PowerSource.current(options: options)
        let mode = lock.withLock { modeProvider }()
        let eff = PowerPolicy.effective(mode, onAC: src.onAC, batteryPercent: src.batteryPercent, lowPowerMode: src.lowPowerMode,
                                        enabled: FeatureFlag.powerPolicy.isEnabled())
        return State(source: src, mode: mode, effective: eff, thermal: Self.thermal(options: options))
    }

    /// Starts watching (idempotent). `mode` reads the setting each time.
    public func start(mode: @escaping @Sendable () -> PerformanceMode) {
        lock.withLock { modeProvider = mode }
        guard tokens.isEmpty else { refresh(); return }
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in self?.refresh() })
        tokens.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.refresh()
        })
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue().refresh()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            runLoopSource = src
        }
        refresh()
    }

    /// Re-reads everything; observers hear about a change only.
    public func refresh() {
        let s = state()
        let (changed, obs) = lock.withLock { () -> (Bool, [@Sendable (State) -> Void]) in
            let c = last != s
            last = s
            return (c, Array(observers.values))
        }
        if changed { obs.forEach { $0(s) } }
    }

    @discardableResult
    public func observe(_ f: @escaping @Sendable (State) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = f }
        return id
    }

    public var current: State? { lock.withLock { last } }
}
