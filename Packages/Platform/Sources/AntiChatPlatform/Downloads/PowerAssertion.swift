// M2.T09 step 5 (R-204, R-207; E.2.5): the Mac does not idle-sleep while a download (or, from T14, a generation) runs —
// `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` — and the assertion is released when idle.
// Assertions die with the process, so a crash never leaves one held. `PowerSource` reads AC / battery / Low Power
// Mode (or `-FakePower ac|battery:<pct>|lowpower`); below 10 % on battery background downloads pause.
import AntiChatFoundation
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

public final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var id: IOPMAssertionID = 0
    private var holders: Set<String> = []
    private let reason: String
    /// Test seam: called with true/false when the assertion is taken/released (the real call still happens).
    private let onChange: (@Sendable (Bool) -> Void)?

    public init(reason: String = "AntiChat is downloading models", onChange: (@Sendable (Bool) -> Void)? = nil) {
        self.reason = reason
        self.onChange = onChange
    }

    deinit { if id != 0 { IOPMAssertionRelease(id) } }

    public var isHeld: Bool { lock.withLock { id != 0 } }
    /// Test seam: the OS assertion id while held (0 otherwise), so tests read back *this* assertion, not any of the
    /// process's assertions with the same name (other suites hold "AntiChat is downloading models" in a full run).
    var assertionID: IOPMAssertionID { lock.withLock { id } }

    /// `holder` = "downloads", "generation", …: the assertion is held while any holder is active.
    public func set(_ holder: String, active: Bool) {
        var changed: Bool?
        lock.withLock {
            if active { holders.insert(holder) } else { holders.remove(holder) }
            if !holders.isEmpty, id == 0 {
                var new: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               reason as CFString, &new) == kIOReturnSuccess {
                    id = new
                    changed = true
                }
            } else if holders.isEmpty, id != 0 {
                IOPMAssertionRelease(id)
                id = 0
                changed = false
            }
        }
        if let changed { onChange?(changed) }
    }
}

public struct PowerSource: Sendable, Equatable {
    public var onAC: Bool
    /// 0…100, nil without a battery.
    public var batteryPercent: Int?
    public var lowPowerMode: Bool

    public init(onAC: Bool, batteryPercent: Int?, lowPowerMode: Bool) {
        self.onAC = onAC; self.batteryPercent = batteryPercent; self.lowPowerMode = lowPowerMode
    }

    public static let pauseBelowPercent = 10

    /// R-207: on battery below 10 % background downloads pause.
    public var pausesDownloads: Bool { !onAC && (batteryPercent ?? 100) < Self.pauseBelowPercent }

    public static func current(options: LaunchOptions = .current) -> PowerSource {
        if let f = options.fakePower {
            if f == "ac" { return PowerSource(onAC: true, batteryPercent: 100, lowPowerMode: false) }
            if f == "lowpower" { return PowerSource(onAC: false, batteryPercent: 50, lowPowerMode: true) }
            if f.hasPrefix("battery:"), let p = Int(f.dropFirst(8)) { return PowerSource(onAC: false, batteryPercent: p, lowPowerMode: false) }
        }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: low)
        }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cap = d[kIOPSCurrentCapacityKey] as? Int ?? 100
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return PowerSource(onAC: ac, batteryPercent: max > 0 ? cap * 100 / max : nil, lowPowerMode: low)
        }
        return PowerSource(onAC: true, batteryPercent: nil, lowPowerMode: low)
    }
}
