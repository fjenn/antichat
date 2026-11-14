// M8.T09 step 1 (R-218 AC2, NFR-PR2; P-platform-09): crash collection. Sources, newest first wins nothing — each is
// one report: (1) macOS crash reports `~/Library/Logs/DiagnosticReports/AntiChat*.ips` / `AntiChatEngine*.ips` newer
// than the last-seen marker (primary: MetricKit is late or silent on macOS), (2) MetricKit `MXCrashDiagnostic`
// payloads stored by `MetricKitCrashSubscriber` as `Diagnostics/crash-<ts>.json`, (3) the vendored
// UncaughtExceptionLogger's `last-crash-reason.log` (NSException name/reason/stack). The payload is technical only:
// exception type, the crashed thread's frames, app/macOS versions, hardware class (chip family + RAM band, never a
// serial) and loaded model ids — the collector has no database handle and never reads chats, files or audio.
// Every payload passes through `Redaction`.
import Foundation
import MetricKit
import OsaurusVendored

public struct CrashReport: Sendable, Equatable, Identifiable {
    public enum Source: String, Sendable { case ips, metricKit, exception }
    public var id: String
    public var source: Source
    public var date: Date
    /// The exact text that would be sent (shown by Preview).
    public var payload: String

    public init(id: String, source: Source, date: Date, payload: String) {
        self.id = id; self.source = source; self.date = date; self.payload = payload
    }
}

public struct CrashContext: Sendable, Equatable {
    public var appVersion: String
    public var macOSVersion: String
    /// "M3 Pro · 32–64 GB" style: chip family + RAM band, never a serial number.
    public var hardwareClass: String
    public var loadedModelIDs: [String]

    public init(appVersion: String, macOSVersion: String, hardwareClass: String, loadedModelIDs: [String] = []) {
        self.appVersion = appVersion; self.macOSVersion = macOSVersion; self.hardwareClass = hardwareClass
        self.loadedModelIDs = loadedModelIDs
    }

    public static func ramBand(_ gb: Int) -> String {
        switch gb {
        case ..<16: "8–15 GB"
        case ..<32: "16–31 GB"
        case ..<64: "32–63 GB"
        case ..<128: "64–127 GB"
        default: "128 GB or more"
        }
    }

    public static func hardwareClass(chipFamily: String?, chip: String, ramGB: Int) -> String {
        "\(chipFamily ?? chip) · \(ramBand(ramGB))"
    }

    public static func current(profile: HardwareProfile?, loadedModelIDs: [String] = []) -> CrashContext {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return CrashContext(
            appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0") + ")",
            macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            hardwareClass: profile.map { hardwareClass(chipFamily: $0.chipFamily, chip: $0.chip, ramGB: $0.ramGB) } ?? "unknown",
            loadedModelIDs: loadedModelIDs)
    }
}

public final class CrashCollector: @unchecked Sendable {
    public let diagnosticsDir: URL
    public let reportsDir: URL
    public let exceptionLog: URL
    public static let ipsPrefixes = ["AntiChat"]  // AntiChat-…, AntiChatEngine-…, AntiChat Dev-…
    public static let maxFrames = 40

    public init(diagnosticsDir: URL,
                reportsDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                exceptionLog: URL? = nil) {
        self.diagnosticsDir = diagnosticsDir; self.reportsDir = reportsDir
        self.exceptionLog = exceptionLog ?? URL(fileURLWithPath: UncaughtExceptionLogger.logPath)
    }

    /// Installs the NSException logger (vendored, UP-OS-000 access) and the MetricKit subscriber. Once per process.
    public static func installHandlers(diagnosticsDir: URL) {
        UncaughtExceptionLogger.install()
        MetricKitCrashSubscriber.shared.start(diagnosticsDir: diagnosticsDir)
    }

    var markerURL: URL { diagnosticsDir.appendingPathComponent("last-seen.json") }

    public func lastSeen() -> Date {
        guard let d = try? Data(contentsOf: markerURL), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Double],
              let t = o["last_seen"] else { return .distantPast }
        return Date(timeIntervalSince1970: t)
    }

    /// A container's first launch starts the marker at now: older reports on this Mac are not this container's to ask
    /// about (and a fresh test container never prompts for the developer's own crash history).
    public func initializeMarkerIfNeeded(_ date: Date = Date()) {
        if !FileManager.default.fileExists(atPath: markerURL.path) { markSeen(date) }
    }

    public func markSeen(_ date: Date = Date()) {
        try? FileManager.default.createDirectory(at: diagnosticsDir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["last_seen": date.timeIntervalSince1970]).write(to: markerURL, options: .atomic)
    }

    /// New crash reports since the marker (nothing is read twice once `markSeen` ran).
    public func pending(context: CrashContext) -> [CrashReport] {
        let since = lastSeen()
        var out: [CrashReport] = []
        let fm = FileManager.default
        func mtime(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        if let names = try? fm.contentsOfDirectory(atPath: reportsDir.path) {
            for n in names where n.hasSuffix(".ips") && Self.ipsPrefixes.contains(where: { n.hasPrefix($0) }) {
                let u = reportsDir.appendingPathComponent(n)
                guard let m = mtime(u), m > since, let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
                out.append(CrashReport(id: n, source: .ips, date: m, payload: Self.payload(ips: text, context: context)))
            }
        }
        if let names = try? fm.contentsOfDirectory(atPath: diagnosticsDir.path) {
            for n in names where n.hasPrefix("crash-") && n.hasSuffix(".json") {
                let u = diagnosticsDir.appendingPathComponent(n)
                guard let m = mtime(u), m > since, let d = try? Data(contentsOf: u) else { continue }
                out.append(CrashReport(id: n, source: .metricKit, date: m, payload: Self.payload(metricKit: d, context: context)))
            }
        }
        if let m = mtime(exceptionLog), m > since, let text = try? String(contentsOf: exceptionLog, encoding: .utf8) {
            out.append(CrashReport(id: "exception-\(Int(m.timeIntervalSince1970))", source: .exception, date: m,
                                   payload: Self.payload(exception: text, context: context)))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: Payloads

    static func header(_ context: CrashContext, kind: String) -> String {
        var s = "AntiChat crash report (\(kind))\n"
        s += "App: \(context.appVersion)\nmacOS: \(context.macOSVersion)\nHardware: \(context.hardwareClass)\n"
        s += "Loaded models: \(context.loadedModelIDs.isEmpty ? "none" : context.loadedModelIDs.joined(separator: ", "))\n"
        return s
    }

    /// A macOS `.ips` report: a one-line JSON header, then the JSON body (exception, threads, usedImages).
    public static func payload(ips text: String, context: CrashContext) -> String {
        var s = header(context, kind: "macOS crash report")
        let firstBreak = text.firstIndex(of: "\n") ?? text.endIndex
        let head = (try? JSONSerialization.jsonObject(with: Data(text[..<firstBreak].utf8))) as? [String: Any]
        let body = (try? JSONSerialization.jsonObject(with: Data(text[firstBreak...].utf8))) as? [String: Any]
        if let head {
            s += "Process: \(head["app_name"] as? String ?? head["name"] as? String ?? "?") \(head["app_version"] as? String ?? "")\n"
            if let t = head["timestamp"] as? String { s += "Time: \(t)\n" }
        }
        guard let body else { return Redaction.redact(s + "Technical details unavailable.\n") }
        if let ex = body["exception"] as? [String: Any] {
            s += "Exception: \(ex["type"] as? String ?? "?") \(ex["signal"] as? String ?? "") \(ex["subtype"] as? String ?? "")\n"
        }
        if let term = body["termination"] as? [String: Any], let ind = term["indicator"] as? String { s += "Termination: \(ind)\n" }
        let images = (body["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = body["threads"] as? [[String: Any]] ?? []
        if let crashed = threads.first(where: { $0["triggered"] as? Bool == true }) ?? threads.first {
            s += "Crashed thread:\n"
            for (i, f) in (crashed["frames"] as? [[String: Any]] ?? []).prefix(maxFrames).enumerated() {
                let idx = f["imageIndex"] as? Int ?? -1
                let image = idx >= 0 && idx < images.count ? images[idx] : "?"
                let sym = f["symbol"] as? String ?? "0x\(String(f["imageOffset"] as? Int ?? 0, radix: 16))"
                s += "  \(i) \(image) \(sym)\n"
            }
        }
        return Redaction.redact(s)
    }

    /// A MetricKit `MXCrashDiagnostic.jsonRepresentation()`.
    public static func payload(metricKit data: Data, context: CrashContext) -> String {
        var s = header(context, kind: "MetricKit")
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Redaction.redact(s + "Technical details unavailable.\n")
        }
        let meta = o["diagnosticMetaData"] as? [String: Any] ?? [:]
        for k in ["exceptionType", "exceptionCode", "signal", "terminationReason", "appVersion", "osVersion", "platformArchitecture"] {
            if let v = meta[k] { s += "\(k): \(v)\n" }
        }
        var frames: [String] = []
        func walk(_ f: [String: Any]) {
            guard frames.count < maxFrames else { return }
            frames.append("\(f["binaryName"] as? String ?? "?") +\(f["offsetIntoBinaryTextSegment"] as? Int ?? 0)")
            for sub in f["subFrames"] as? [[String: Any]] ?? [] { walk(sub) }
        }
        let threads = ((o["callStackTree"] as? [String: Any])?["callStacks"] as? [[String: Any]]) ?? []
        if let crashed = threads.first(where: { $0["threadAttributed"] as? Bool == true }) ?? threads.first {
            for root in crashed["callStackRootFrames"] as? [[String: Any]] ?? [] { walk(root) }
        }
        s += "Crashed thread:\n" + frames.enumerated().map { "  \($0.offset) \($0.element)\n" }.joined()
        return Redaction.redact(s)
    }

    /// The vendored UncaughtExceptionLogger's dump (name, reason, stack; `userInfo` dropped).
    public static func payload(exception text: String, context: CrashContext) -> String {
        var s = header(context, kind: "uncaught exception")
        var inStack = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("userInfo:") { continue }
            if t.hasPrefix("name:") || t.hasPrefix("reason:") || t.hasPrefix("timestamp:") { s += t + "\n"; continue }
            if t == "stack:" { inStack = true; s += "stack:\n"; continue }
            if inStack, !t.isEmpty { s += "  \(t)\n" }
        }
        return Redaction.redact(s)
    }
}

/// MetricKit subscriber: stores each crash diagnostic as `Diagnostics/crash-<ts>.json` (read at the next launch).
public final class MetricKitCrashSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    public static let shared = MetricKitCrashSubscriber()
    private var dir: URL?
    private let lock = NSLock()

    func start(diagnosticsDir: URL) {
        lock.lock(); defer { lock.unlock() }
        guard dir == nil else { return }
        dir = diagnosticsDir
        MXMetricManager.shared.add(self)
    }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for p in payloads {
            for (i, c) in (p.crashDiagnostics ?? []).enumerated() {
                let ts = Int(p.timeStampEnd.timeIntervalSince1970)
                try? c.jsonRepresentation().write(to: dir.appendingPathComponent("crash-\(ts)-\(i).json"), options: .atomic)
            }
        }
    }
}
