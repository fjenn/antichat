// M8.T09 (R-218): the composition side of diagnostics. Installs the crash handlers and the app's file log at the
// first window, decides the next-launch crash prompt (never during onboarding), builds the system report and the log
// bundle, and hands reports to Mail (NSSharingService.composeEmail) or the browser (GitHub issue form) — AntiChat
// itself sends nothing. `-SimulateCrashOnNextLaunch YES` (DEBUG) writes a synthetic MetricKit crash file first.
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AppKit
import Foundation
import Synchronization

@MainActor
final class DiagnosticsCenter {
    static let shared = DiagnosticsCenter()

    var diagnosticsDir: URL { AppDatabase.containerURL().appendingPathComponent("Diagnostics", isDirectory: true) }
    var collector: CrashCollector { CrashCollector(diagnosticsDir: diagnosticsDir) }
    var endpoints: ReportEndpoints? { ReportEndpoints.fromBundle() }
    let handoff = SystemReportHandoff()
    /// The main window's chats database (System report perf numbers when a sheet has none of its own).
    nonisolated(unsafe) var database: AppDatabase?
    /// Reports waiting for the prompt (set by `checkAtLaunch`).
    var pendingReports: [CrashReport] = []
    private var started = false

    var controller: CrashPromptController {
        CrashPromptController(collector: collector, defaults: .antichat, endpoints: endpoints, handoff: handoff)
    }

    nonisolated func context() -> CrashContext { CrashContext.current(profile: EnginePolicy.profile.withLock { $0 }) }

    /// Once per process: handlers, the app's file log, then the prompt decision. True when the prompt should show.
    func checkAtLaunch() -> Bool {
        guard !started else { return false }
        started = true
        // Only the app itself (not the package test runner), and only with the flag on.
        guard FeatureFlag.diagnostics.isEnabled(), Bundle.main.bundleURL.pathExtension == "app" else { return false }
        CrashCollector.installHandlers(diagnosticsDir: diagnosticsDir)
        AppLog.bootstrap(process: "app", directory: LogBundleBuilder.logsRoot().appendingPathComponent("app", isDirectory: true))
        collector.initializeMarkerIfNeeded()
        #if DEBUG
        if AppDefaults.standard.bool(forKey: "SimulateCrashOnNextLaunch") { writeSyntheticCrash() }
        #endif
        switch controller.decide(context: context(), onboardingComplete: !OnboardingGate.shouldShow()) {
        case .prompt(let r):
            pendingReports = r
            return true
        case .autoSend, .none:
            return false
        }
    }

    #if DEBUG
    func writeSyntheticCrash() {
        try? FileManager.default.createDirectory(at: diagnosticsDir, withIntermediateDirectories: true)
        let json = #"{"diagnosticMetaData":{"exceptionType":1,"signal":11,"appVersion":"dev","osVersion":"macOS"},"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"AntiChat","offsetIntoBinaryTextSegment":4096,"subFrames":[{"binaryName":"libswiftCore.dylib","offsetIntoBinaryTextSegment":512}]}]}]}}"#
        try? Data(json.utf8).write(to: diagnosticsDir.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970))-sim.json"))
    }
    #endif

    /// The helper's resident set + load times from the last `liveSystemReport` (the sync log-bundle path reuses it).
    nonisolated let engineState = Mutex<(models: [SystemReport.LoadedModel], loadsMs: [Double])>(([], []))

    nonisolated func systemReport(database: AppDatabase?) -> SystemReport {
        let engine = engineState.withLock { $0 }
        return SystemReport.collect(profile: EnginePolicy.profile.withLock { $0 }, database: database ?? self.database,
                                    catalog: CatalogLaunch.shared?.snapshot, loadedModels: engine.models,
                                    lastLoadTimesMs: engine.loadsMs)
    }

    /// Asks a connected helper session for its ModelScheduler resident set and load-time log first (never starts the
    /// helper), then builds the report. No session → the last known state ("none" before any model ran).
    nonisolated func liveSystemReport(database: AppDatabase?) async -> SystemReport {
        if let p = await EngineClient.probeConnected() {
            let bytes = p.residentBytes ?? Dictionary(uniqueKeysWithValues: p.residentModels.map { ($0, UInt64(0)) })
            engineState.withLock { $0 = (SystemReport.loadedModels(residentBytes: bytes), p.loadTimesMs ?? []) }
        }
        return systemReport(database: database)
    }

    var engineLogDir: URL {
        let own = LogBundleBuilder.logsRoot().appendingPathComponent("engine")
        return FileManager.default.fileExists(atPath: own.path) ? own
            : LogBundleBuilder.logsRoot(debug: true).appendingPathComponent("engine")  // the helper writes under AntiChat-Dev
    }

    /// The bundle's inputs are gathered here; reading, redacting and zipping the logs runs off the main thread
    /// (review fix: up to 25 MB of logs and thousands of redactions were a multi-second beachball).
    func buildLogBundle(to url: URL, includeContent: Bool, database: AppDatabase?) async throws {
        let input = LogBundleInput(
            appLogDir: LogBundleBuilder.logsRoot().appendingPathComponent("app"), engineLogDir: engineLogDir,
            crashes: collector.pending(context: context()) + recentCrashes(), systemReport: systemReport(database: database),
            engineState: ["budget_gb": EnginePolicy.profile.withLock { $0 }.map { String($0.B) } ?? "unknown"],
            includeContent: includeContent)
        try await Task.detached(priority: .userInitiated) { try LogBundleBuilder.build(to: url, input: input) }.value
    }

    /// Crash files already seen (the bundle still carries them; the marker only stops the prompt).
    func recentCrashes() -> [CrashReport] {
        let c = CrashCollector(diagnosticsDir: diagnosticsDir)
        let ctx = context()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: diagnosticsDir.path)) ?? []
        return names.filter { $0.hasPrefix("crash-") && $0.hasSuffix(".json") }.sorted().suffix(5).compactMap { n in
            guard let d = try? Data(contentsOf: c.diagnosticsDir.appendingPathComponent(n)) else { return nil }
            return CrashReport(id: n, source: .metricKit, date: Date(), payload: CrashCollector.payload(metricKit: d, context: ctx))
        }
    }
}

/// Mail through the user's mail client, GitHub through the browser (+ the full text on the clipboard).
final class SystemReportHandoff: ReportHandoff, @unchecked Sendable {
    func openGitHub(_ url: URL, fullText: String) {
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(fullText, forType: .string)
            NSWorkspace.shared.open(url)
        }
    }

    /// Called on the main thread (the sheet's buttons, the launch check).
    func composeEmail(to: String, subject: String, body: String, attachments: [URL]) -> Bool {
        MainActor.assumeIsolated {
            guard let service = NSSharingService(named: .composeEmail) else { return false }
            let items: [Any] = [body] + attachments
            guard service.canPerform(withItems: items) else { return false }
            service.recipients = [to]
            service.subject = subject
            service.perform(withItems: items)
            return true
        }
    }
}
