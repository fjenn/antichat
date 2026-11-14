// M2.T01 (R-200, G-049; P-platform-01): pure classification of the Mac's raw facts into a RAM tier, sub-band, memory
// budget B and speed class (hardware-tiers §2.1-§2.3, blueprint E §E.2.1 step 3). No I/O here: HardwareProbe
// gathers the facts, this file only computes, so TierClassifierTests run every fixture without hardware.
import Foundation

/// RAM tier (hardware-tiers §2.2). The user sees only the tier; the selector uses the exact budget.
public enum HardwareTier: String, Codable, Sendable, CaseIterable, Comparable {
    case T0, T1, T2, T3, T4
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

/// Compute speed class, the second selection axis (hardware-tiers §2.3; pp512 proxy).
public enum SpeedClass: String, Codable, Sendable, CaseIterable, Comparable {
    case S1, S2, S3, S4
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}

/// Where the speed class came from: the bandwidth table, the unknown-chip MicroProbe (K-054), or neither yet
/// (unknown chip before its probe ran: conservative S1 until then).
public enum SpeedClassSource: String, Codable, Sendable { case table, probe, pending }

/// The raw facts the probe reads (sysctl, IOKit, Metal, OS, disk, power). Also the `-FakeHardware` fixture shape
/// (`fixtures/hardware/<name>.json`, written by tools/fixtures/gen-hardware.py).
public struct HardwareFacts: Codable, Sendable, Equatable {
    public var brandString: String
    public var memBytes: UInt64
    public var pCores: Int?
    public var eCores: Int?
    public var gpuModel: String?
    public var gpuCores: Int?
    public var workingSetBytes: UInt64?
    public var osVersion: String
    public var osBuild: String
    public var freeDiskBytes: Int64?
    public var powerSource: String?
    public var fmAvailable: Bool
    public var memoryStatusLevel: Int?
    /// A recorded MicroProbe result (fixtures for unknown chips); the live probe fills it at runtime.
    public var microProbe: MicroProbe.Result?

    public init(brandString: String, memBytes: UInt64, pCores: Int? = nil, eCores: Int? = nil, gpuModel: String? = nil,
                gpuCores: Int? = nil, workingSetBytes: UInt64? = nil, osVersion: String, osBuild: String,
                freeDiskBytes: Int64? = nil, powerSource: String? = nil, fmAvailable: Bool = false,
                memoryStatusLevel: Int? = nil, microProbe: MicroProbe.Result? = nil) {
        self.brandString = brandString; self.memBytes = memBytes; self.pCores = pCores; self.eCores = eCores
        self.gpuModel = gpuModel; self.gpuCores = gpuCores; self.workingSetBytes = workingSetBytes
        self.osVersion = osVersion; self.osBuild = osBuild; self.freeDiskBytes = freeDiskBytes
        self.powerSource = powerSource; self.fmAvailable = fmAvailable; self.memoryStatusLevel = memoryStatusLevel
        self.microProbe = microProbe
    }

    /// Marketing RAM in GB (8, 16, 18, …): `hw.memsize` in GiB, rounded.
    public var ramGB: Int { Int((Double(memBytes) / 1_073_741_824).rounded()) }
    /// W in GB (1 GB = 1e9 B, the unit of catalog footprints).
    public var workingSetGB: Double? { workingSetBytes.map { Double($0) / 1e9 } }
    /// "M4 Max" from "Apple M4 Max" (the bandwidth table key).
    public var chipName: String {
        let s = brandString.trimmingCharacters(in: .whitespaces)
        return s.hasPrefix("Apple ") ? String(s.dropFirst(6)) : s
    }

    /// Decodes a `fixtures/hardware/<name>.json` file (raw sysctl/IOKit/Metal keys).
    public init(fixture data: Data) throws {
        struct F: Decodable {
            var sysctl: [String: Value]
            var ioreg: [String: Value]
            var metal: [String: UInt64]
            var os: [String: String]
            var volume: [String: Int64]?
            var power: [String: String]?
            var fmAvailable: Bool?
            var microProbe: MicroProbe.Result?
        }
        enum Value: Decodable {
            case int(Int64), string(String)
            init(from d: Decoder) throws {
                let c = try d.singleValueContainer()
                if let i = try? c.decode(Int64.self) { self = .int(i) } else { self = .string(try c.decode(String.self)) }
            }
            var int: Int64? { if case .int(let i) = self { i } else { nil } }
            var string: String? { if case .string(let s) = self { s } else { nil } }
        }
        let f = try JSONDecoder().decode(F.self, from: data)
        self.init(
            brandString: f.sysctl["machdep.cpu.brand_string"]?.string ?? "unknown",
            memBytes: UInt64(f.sysctl["hw.memsize"]?.int ?? 0),
            pCores: f.sysctl["hw.perflevel0.physicalcpu"]?.int.map(Int.init),
            eCores: f.sysctl["hw.perflevel1.physicalcpu"]?.int.map(Int.init),
            gpuModel: f.ioreg["AGXAccelerator.model"]?.string,
            gpuCores: f.ioreg["AGXAccelerator.gpu-core-count"]?.int.map(Int.init),
            workingSetBytes: f.metal["recommendedMaxWorkingSetSize"],
            osVersion: f.os["version"] ?? "26.0", osBuild: f.os["build"] ?? "",
            freeDiskBytes: f.volume?["availableCapacityForImportantUsage"],
            powerSource: f.power?["source"], fmAvailable: f.fmAvailable ?? false,
            memoryStatusLevel: f.sysctl["kern.memorystatus_level"]?.int.map(Int.init),
            microProbe: f.microProbe)
    }
}

/// `bandwidth.json` (ported llmfit table + per-GPU-core rows + speed classes).
public struct BandwidthTable: Sendable {
    public struct Row: Codable, Sendable, Equatable {
        public var chip: String
        public var gpuCores: Int?
        public var ramGB: Int?
        public var bandwidthGBs: Double
        public var speedClass: SpeedClass
        /// M5 base before macOS 26.2 (no MLX Neural Accelerators yet): one class lower (hardware-tiers §2.3).
        public var speedClassBeforeOS26_2: SpeedClass?
    }
    public let rows: [Row]
    public init(rows: [Row]) { self.rows = rows }

    /// The bundled table (`Resources/bandwidth.json`).
    public static let bundled: BandwidthTable = {
        struct Doc: Decodable { var rows: [Row] }
        guard let url = Bundle.module.url(forResource: "bandwidth", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url), let doc = try? JSONDecoder().decode(Doc.self, from: data)
        else { return BandwidthTable(rows: []) }
        return BandwidthTable(rows: doc.rows)
    }()

    /// chip + gpuCores, then chip + ramGB, then the chip's generic row; nil for an unknown chip.
    public func lookup(chip: String, gpuCores: Int?, ramGB: Int) -> Row? {
        let same = rows.filter { $0.chip.caseInsensitiveCompare(chip) == .orderedSame }
        if let g = gpuCores, let r = same.first(where: { $0.gpuCores == g }) { return r }
        if let r = same.first(where: { $0.gpuCores == nil && $0.ramGB == ramGB }) { return r }
        return same.first { $0.gpuCores == nil && $0.ramGB == nil } ?? same.first
    }
}

public enum TierClassifier {
    public struct Result: Sendable, Equatable {
        public var tier: HardwareTier
        public var subband: String?
        /// Memory budget B in GB (hardware-tiers §2.1).
        public var budgetGB: Double
        public var speedClass: SpeedClass
        public var speedClassSource: SpeedClassSource
        public var bandwidthGBs: Double?
    }

    /// Tier by RAM (hardware-tiers §2.2): 8 → T0, 16-18 → T1, 24-36 → T2, 48-64 → T3, 96+ → T4.
    public static func tier(ramGB: Int) -> HardwareTier {
        switch ramGB {
        case ..<12: .T0
        case ..<20: .T1
        case ..<40: .T2
        case ..<80: .T3
        default: .T4
        }
    }

    /// H_os, the macOS + typical apps headroom (hardware-tiers §2.1, K-003): 8→3.5 · 16→6 · 18→6 · 24→7 ·
    /// 32/36→8 · 48→10 · 64→12 · 96→14 · 128+→16. Between table rows the next lower row applies.
    public static func headroomGB(ramGB: Int) -> Double {
        let table: [(Int, Double)] = [(8, 3.5), (16, 6), (18, 6), (24, 7), (32, 8), (36, 8), (48, 10), (64, 12), (96, 14), (128, 16)]
        return table.last(where: { $0.0 <= ramGB })?.1 ?? 3.5
    }

    /// App shell reserve inside B (hardware-tiers §2.1).
    public static let appShellGB = 0.5

    /// `B = min(W, RAM − H_os − 0.5)`; without a W reading, the RAM term alone.
    public static func budgetGB(ramGB: Int, workingSetGB: Double?) -> Double {
        let ramTerm = Double(ramGB) - headroomGB(ramGB: ramGB) - appShellGB
        return max(0, min(workingSetGB ?? ramTerm, ramTerm))
    }

    /// Sub-bands exist only in T2 {24, 32, 36} and T4 {96, 128+} (hardware-tiers §2.2), e.g. "T2-24".
    public static func subband(tier: HardwareTier, ramGB: Int) -> String? {
        switch tier {
        case .T2: return "T2-\([24, 32, 36].last(where: { $0 <= ramGB }) ?? 24)"
        case .T4: return "T4-\(ramGB >= 128 ? 128 : 96)"
        default: return nil
        }
    }

    /// Facts → tier, sub-band, B, speed class. A chip missing from the table takes its speed class from the
    /// MicroProbe result (`speedClassSource = .probe`), else S1 until the probe has run (`.pending`).
    public static func classify(facts: HardwareFacts, table: BandwidthTable = .bundled) -> Result {
        let ram = facts.ramGB
        let t = tier(ramGB: ram)
        let b = budgetGB(ramGB: ram, workingSetGB: facts.workingSetGB)
        var speed = SpeedClass.S1
        var source = SpeedClassSource.pending
        var bandwidth: Double?
        if let row = table.lookup(chip: facts.chipName, gpuCores: facts.gpuCores, ramGB: ram) {
            speed = row.speedClass
            if let before = row.speedClassBeforeOS26_2, osVersion(facts.osVersion, isBelow: (26, 2)) { speed = before }
            source = .table
            bandwidth = row.bandwidthGBs
        } else if let probe = facts.microProbe {
            speed = probe.speedClass
            source = .probe
            bandwidth = probe.bandwidthGBs
        }
        return Result(tier: t, subband: subband(tier: t, ramGB: ram), budgetGB: b, speedClass: speed,
                      speedClassSource: source, bandwidthGBs: bandwidth)
    }

    static func osVersion(_ v: String, isBelow target: (Int, Int)) -> Bool {
        let parts = v.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0, minor = parts.count > 1 ? parts[1] : 0
        return (major, minor) < target
    }
}
