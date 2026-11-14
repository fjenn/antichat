// M8.T03 step 6 (R-246 AC2): app wiring of the propose-only memory review. The launch registers the tier default of
// "Suggest things to remember" (off on T0–T1), then every 15 minutes the gates are checked with this Mac's power
// (IOKit: AC adapter, Low Power Mode), idle time (CGEventSource), thermal state and running turns; a run writes
// pending suggestions only. The last-run stamp is app state (not a setting).
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import CoreGraphics
import Defaults
import Foundation
import GRDB
import IOKit.ps

struct SystemPower: PowerSource {
    var onACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }
    var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }
}

struct SystemIdle: IdleClock {
    var idleSeconds: Double { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) }
}

struct SystemThermal: ThermalSource {
    var isFairOrBetter: Bool { ProcessInfo.processInfo.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue }
}

@MainActor
public final class MemoryReviewScheduler {
    static let lastRunKey = "memoryReviewLastRun"
    private var timer: Timer?
    private let runtime: MemoryRuntime
    private let model: (any MemoryDecisionModel)?
    private var running = false

    /// Registers the tier default (T0/T1 off) — call once at launch, before Settings reads the key.
    public static func registerDefault(tier: String) {
        UserDefaults.antichat.register(defaults: [Defaults.Keys.memoryReviewEnabled.name: MemoryReviewService.defaultEnabled(tier: tier)])
    }

    init(runtime: MemoryRuntime, model: (any MemoryDecisionModel)?) {
        self.runtime = runtime
        self.model = model
    }

    @discardableResult
    public static func start(database: AppDatabase, model: (any MemoryDecisionModel)?) -> MemoryReviewScheduler? {
        guard !database.isInMemory, FeatureFlag.memory.isEnabled(.antichat) else { return nil }
        let s = MemoryReviewScheduler(runtime: MemoryRuntime.for(database), model: model)
        s.timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak s] _ in MainActor.assumeIsolated { s?.tick() } }
        return s
    }

    func tick() {
        guard !running else { return }
        let db = runtime.database
        let gates = MemoryReviewService.Gates(
            enabled: Defaults[.memoryReviewEnabled], policy: runtime.policy(), power: SystemPower(), idle: SystemIdle(),
            thermal: SystemThermal(),
            busy: {  // a reply or a picture/video job running (step 6; review fix: media jobs too)
                (MediaJobQueue.shared?.hasRunning ?? false)
                    || ((try? db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM message WHERE status IN ('pending','streaming')") }) ?? 1) > 0
            })
        let last = UserDefaults.antichat.object(forKey: Self.lastRunKey) as? Date
        let service = MemoryReviewService(store: runtime.store, model: model, embedder: runtime.embedder)
        guard service.skipReason(gates, lastRun: last) == nil else { return }
        running = true
        Task.detached(priority: .utility) { [weak self] in
            let n = (try? await service.run(gates, lastRun: last).count) ?? 0
            AppLog.log(.store, .info, "memory review: \(n) suggestion(s)")
            await MainActor.run {
                UserDefaults.antichat.set(Date(), forKey: Self.lastRunKey)
                self?.running = false
            }
        }
    }
}
