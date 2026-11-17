// M2.T01 step 4 (R-200 AC1/AC6; P-platform-01): reads the Mac's facts through the vendored `ChipProfile`
// (UP-OS-014 probes) plus power, free disk and Apple Intelligence availability, classifies them and caches the
// profile in `hardware_profile`. Budget < 50 ms without MicroProbe; never spawns `system_profiler`.
// Re-probe when `os_build` changed, W moved by > 2 %, or there is no row. `-FakeHardware <fixture|T0…T4>` (DEBUG)
// loads `fixtures/hardware/<fixture>.json` instead; `-FakeFreeDiskGB <n>` overrides free disk.
import Foundation
import IOKit.ps
import Metal
import AntiChatFoundation
import AntiChatStorage
import OsaurusVendored
#if canImport(FoundationModels)
import FoundationModels
#endif

public actor HardwareProbe {
    public static let shared = HardwareProbe()

    private var cached: HardwareProfile?

    public init() {}

    /// The profile for this launch: fixture (DEBUG), else the cached row when still valid, else a fresh probe
    /// written back to `database`. Unknown chips get their MicroProbe once, here (call off-main, after first window).
    public func current(database: AppDatabase?, options: LaunchOptions = .current,
                        dataRoot: URL? = nil, runMicroProbe: Bool = true) -> HardwareProfile {
        if let cached { return cached }
        var profile: HardwareProfile
        if let fixture = Self.fixtureProfile(options: options) {
            profile = fixture
        } else {
            var facts = Self.liveFacts(volume: dataRoot)
            let row = database.flatMap { try? HardwareProfileRecord.load($0) }
            let old = row.flatMap { try? JSONDecoder().decode(HardwareProfile.self, from: Data($0.profileJSON.utf8)) }
            if let old, !Self.needsReprobe(cached: old, osBuild: facts.osBuild, workingSetGB: facts.workingSetGB) {
                facts.microProbe = old.microProbe
            }
            let table = BandwidthTable.bundled
            if facts.microProbe == nil, runMicroProbe,
               table.lookup(chip: facts.chipName, gpuCores: facts.gpuCores, ramGB: facts.ramGB) == nil {
                facts.microProbe = MicroProbe.run()
            }
            profile = HardwareProfile(facts: facts, classification: TierClassifier.classify(facts: facts, table: table))
            if let database, let record = Self.record(profile) { try? record.save(database) }
        }
        if let gb = options.fakeFreeDiskGB { profile.freeDiskGB = gb }
        cached = profile
        return profile
    }

    /// Drops the in-memory copy (tests; a disk change re-reads free space).
    public func invalidate() { cached = nil }

    /// R-200 AC6 re-probe rule: a changed `os_build`, or W differing by more than 2 %.
    public static func needsReprobe(cached: HardwareProfile, osBuild: String, workingSetGB: Double?) -> Bool {
        if cached.osBuild != osBuild { return true }
        switch (cached.W, workingSetGB) {
        case let (old?, new?): return abs(new - old) / max(old, 0.001) > 0.02
        case (nil, nil): return false
        default: return true
        }
    }

    // MARK: - Live facts

    /// One synchronous read of every fact (sysctl, IOKit, Metal, power, FoundationModels, and disk unless
    /// `includeDisk` is false). The disk read (`volumeAvailableCapacityForImportantUsage`, ~70 ms: it sizes purgeable
    /// space) is outside the < 50 ms probe budget; it runs in the same off-main launch task.
    public static func liveFacts(volume: URL? = nil, includeDisk: Bool = true) -> HardwareFacts {
        let chip = ChipProfile.detect()
        return HardwareFacts(
            brandString: chip.brandString,
            memBytes: chip.physicalMemoryBytes,
            pCores: ChipProfile.performanceCoreCount(),
            eCores: ChipProfile.efficiencyCoreCount(),
            gpuModel: ChipProfile.gpuModelName(),
            gpuCores: chip.gpuCoreCount,
            workingSetBytes: chip.recommendedMaxWorkingSetBytes,
            osVersion: osVersionString(),
            osBuild: sysctlString("kern.osversion") ?? "",
            freeDiskBytes: includeDisk
                ? freeDiskBytes(at: volume ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
                : nil,
            powerSource: powerSource(),
            fmAvailable: foundationModelsAvailable(),
            memoryStatusLevel: ChipProfile.memoryStatusLevel())
    }

    static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// `volumeAvailableCapacityForImportantUsage` (counts purgeable space, as Finder does). Walks up to an existing
    /// ancestor so a not-yet-created Models folder still reports its volume.
    public static func freeDiskBytes(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func powerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
        switch type {
        case kIOPMACPowerKey: return "ac"
        case kIOPMBatteryPowerKey: return "battery"
        case kIOPMUPSPowerKey: return "ups"
        default: return type
        }
    }

    static func foundationModelsAvailable() -> Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    // MARK: - Fixtures (DEBUG)

    /// `-FakeHardware` tier shorthands map to one fixture each.
    public static let tierFixtures: [LaunchOptions.Tier: String] = [
        .T0: "t0-m1-8", .T1: "t1-m2-16", .T2: "t2-m4-24", .T3: "t3-m4pro-48", .T4: "t4-m3max-96",
    ]

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// `fixtures/hardware`: `$ANTICHAT_FIXTURES/hardware` when it has the file, else the source checkout's.
    public static func fixtureURL(_ name: String) -> URL? {
        var roots: [URL] = []
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        roots.append(repo.appendingPathComponent("fixtures"))
        if let env = ProcessInfo.processInfo.environment["ANTICHAT_FIXTURES"], !env.isEmpty {
            roots.append(URL(fileURLWithPath: env))
        }
        return roots.map { $0.appendingPathComponent("hardware/\(name).json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    #endif

    public static func fixtureProfile(options: LaunchOptions) -> HardwareProfile? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        guard let name = options.fakeHardwareFixture ?? options.fakeHardware.flatMap({ tierFixtures[$0] }) else { return nil }
        guard let url = fixtureURL(name), let data = try? Data(contentsOf: url),
              let facts = try? HardwareFacts(fixture: data) else {
            AppLog.log(.store, .error, "-FakeHardware \(name): fixture not found")
            return nil
        }
        return HardwareProfile(facts: facts, classification: TierClassifier.classify(facts: facts), fixture: name)
        #else
        return nil
        #endif
    }

    static func record(_ p: HardwareProfile) -> HardwareProfileRecord? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .deferredToDate
        guard let data = try? enc.encode(p) else { return nil }
        return HardwareProfileRecord(osBuild: p.osBuild, chip: p.chip, gpuCores: p.gpuCores, ram: p.ramGB, w: p.W, b: p.B,
                                     tier: p.tier.rawValue, speedClass: p.speedClass.rawValue, probedAt: p.probedAt,
                                     profileJSON: String(decoding: data, as: UTF8.self))
    }

    /// `-PrintHardwareProfile YES`: the profile as pretty JSON (at-200-live.sh compares it with system_profiler).
    public static func printableJSON(_ p: HardwareProfile) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? enc.encode(p)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
