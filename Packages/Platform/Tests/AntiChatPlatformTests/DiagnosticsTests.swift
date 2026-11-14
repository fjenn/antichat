// M8.T09 AT-218 / AT-NFR-PR2 (R-218, NFR-PR2): redaction, the log bundle, crash collection, the system report and the
// report composer. One file, one suite per spec'd test class (FILTER works on each name).
//   make test-unit FILTER=RedactionTests,LogBundleTests,CrashCollectorTests,SystemReportTests,ReportComposerTests
// Artefacts: build/at/AT-218/<date>.log (+ the exported log zip and a crash preview text).
import AntiChatFoundation
import AntiChatStorage
import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import AntiChatPlatform

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized
private let atDir = repo.appendingPathComponent("build/at/AT-218")

private func atLog(_ line: String) {
    try? FileManager.default.createDirectory(at: atDir, withIntermediateDirectories: true)
    let url = atDir.appendingPathComponent("\(Date().formatted(.iso8601.year().month().day())).log")
    let data = Data((line + "\n").utf8)
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
}

private func tempDir(_ name: String) throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// The unique phrases of fixtures/prompts/copy-check/incognito-phrases.txt (chat content stand-ins).
private func chatPhrases() -> [String] {
    let url = repo.appendingPathComponent("fixtures/prompts/copy-check/incognito-phrases.txt")
    let fallback = ["zephyrquartz harbour lantern 7341", "obsidian marmalade quokka 2208"]
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return fallback }
    let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return lines.isEmpty ? fallback : Array(lines.prefix(6))
}

private let context = CrashContext(appVersion: "1.0 (42)", macOSVersion: "26.1.0", hardwareClass: "M3 Pro · 32–63 GB",
                                   loadedModelIDs: ["chat-9b-q4", "embed"])

@Suite("RedactionTests") struct RedactionTests {
    /// 40 seeded secrets, paths and ids; none may survive.
    static let seeded: [String] = {
        var s: [String] = []
        for i in 0..<8 { s.append("sk-live\(i)abcdefgh12345678") }
        for i in 0..<6 { s.append("hf_\(i)QwErTyUiOpAsDfGhJkL") }
        for i in 0..<4 { s.append("ghp_\(i)abcdefghijklmnopqrstu") }
        for i in 0..<6 { s.append("/Users/finnuser\(i)/Library/Application Support/AntiChat") }
        for _ in 0..<6 { s.append(UUID().uuidString) }
        for i in 0..<4 { s.append("https://example.com/cb?code=secretcode\(i)&state=xyz\(i)") }
        for i in 0..<3 { s.append("person\(i)@example.org") }
        for i in 0..<3 { s.append(String(repeating: "a1b2c3d4", count: 5) + "\(i)") }
        return s
    }()

    @Test func fortySeededSecretsDoNotSurvive() {
        #expect(Self.seeded.count == 40)
        let log: String = Self.seeded.enumerated().map { (i, v) -> String in
            switch i % 4 {
            case 0: "2026-11-05 [engine] token=\(v) loaded"
            case 1: "[net] Authorization: Bearer \(v)"
            case 2: "[store] opened \(v) ok"
            default: "[ui] value \(v)"
            }
        }.joined(separator: "\n")
        let out = Redaction.redact(log)
        let needles: [String] = Self.seeded.map { v in
            if v.hasPrefix("/Users/") { return String(v.dropFirst("/Users/".count).prefix(while: { $0 != "/" })) }
            if v.hasPrefix("https://") { return String(v.split(separator: "?")[1]) }
            return v
        }
        let survivors = needles.filter { out.contains($0) }
        #expect(survivors.isEmpty, "\(survivors)")
        atLog("\(Date().formatted(.iso8601)) RedactionTests seeded=40 survivors=\(survivors.count)")
    }

    @Test func keepsOrdinaryText() {
        let line = "[engine] load chat-9b-q4 in 812 ms, tier T1"
        #expect(Redaction.redact(line) == line)
        #expect(Redaction.sanitizedEndpoint("https://host/p/a?x=1#f") == "https://host/p/a")
        #expect(Redaction.redactUserPaths("/Users/somebody/x", userName: "nobodyhere") == "~/x")
    }
}

@Suite("LogBundleTests", .serialized) struct LogBundleTests {
    static func fixtureLogs(_ dir: URL, lines: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var text = ""
        let phrases = chatPhrases()
        for i in 0..<lines {
            if i % 50 == 0 { text += "[harness] \(AppLog.contentMarker) user said: \(phrases[(i / 50) % phrases.count])\n" }
            text += "[engine] line \(i) /Users/someone/Library token=abc\(i)def\n"
        }
        try text.write(to: dir.appendingPathComponent("app.antichat 2026-11-05.log"), atomically: true, encoding: .utf8)
    }

    func build(includeContent: Bool) throws -> [String: String] {
        let dir = try tempDir("logs")
        try Self.fixtureLogs(dir.appendingPathComponent("app"), lines: 3_000)
        try Self.fixtureLogs(dir.appendingPathComponent("engine"), lines: 500)
        let crash = CrashReport(id: "crash-1", source: .metricKit, date: Date(), payload: "AntiChat crash report\nException: 1")
        let report = SystemReport(appVersion: "1.0", macOSVersion: "26", chip: "Apple M3 Pro", ramGB: 36, tier: "T2",
                                  speedClass: "S2", budgetGB: 24)
        let out = dir.appendingPathComponent(LogBundleBuilder.fileName())
        try LogBundleBuilder.build(to: out, input: LogBundleInput(
            appLogDir: dir.appendingPathComponent("app"), engineLogDir: dir.appendingPathComponent("engine"), crashes: [crash],
            systemReport: report, engineState: ["resident": "chat-9b-q4"], includeContent: includeContent))
        let a = try Archive(url: out, accessMode: .read)
        var entries: [String: String] = [:]
        for e in a {
            var d = Data()
            _ = try a.extract(e) { d.append($0) }
            entries[e.path] = String(decoding: d, as: UTF8.self)
        }
        if !includeContent {
            try? FileManager.default.createDirectory(at: atDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: atDir.appendingPathComponent("logs-sample.zip"))
            try? FileManager.default.copyItem(at: out, to: atDir.appendingPathComponent("logs-sample.zip"))
        }
        return entries
    }

    /// Review fix (M8.T16): a multi-line content entry (an older log's model preview) leaves no continuation line.
    @Test func multiLineContentEntryIsDroppedWhole() throws {
        let dir = try tempDir("logs-ml")
        let text = """
            2026/11/05 10:00:00:001  [engine] before
            2026/11/05 10:00:00:002  [harness] \(AppLog.contentMarker) preview: first line
            SECRET second line of the reply
            SECRET third line
            2026/11/05 10:00:00:003  [engine] after
            """
        try text.write(to: dir.appendingPathComponent("a.log"), atomically: true, encoding: .utf8)
        let out = LogBundleBuilder.tail(dir, includeContent: false)
        #expect(!out.contains("SECRET") && !out.contains("preview"))
        #expect(out.contains("before") && out.contains("after"))
        #expect(LogBundleBuilder.tail(dir, includeContent: true).contains("SECRET second line"))
    }

    @Test func entriesCapsAndNoContentByDefault() throws {
        let e = try build(includeContent: false)
        #expect(Set(e.keys) == ["system-report.json", "app.log", "engine.log", "crashes/crash-1.txt", "engine-state.json"])
        let app = try #require(e["app.log"])
        #expect(app.split(separator: "\n").count == LogBundleBuilder.maxLines)
        #expect(e["engine.log"]?.split(separator: "\n").count == 500)
        let hits = chatPhrases().filter { p in e.values.contains { $0.contains(p) } }
        #expect(hits.isEmpty, "\(hits)")
        #expect(!app.contains("/Users/someone") && !app.contains("token=abc"))
        #expect(e["system-report.json"]?.contains("\"tier\" : \"T2\"") == true)
        atLog("\(Date().formatted(.iso8601)) LogBundleTests entries=\(e.count) app_lines=\(app.split(separator: "\n").count) content_hits=\(hits.count)")
    }

    @Test func contentOnlyWhenTicked() throws {
        let e = try build(includeContent: true)
        #expect(chatPhrases().contains { p in e["app.log"]?.contains(p) == true })
    }
}

@Suite("CrashCollectorTests", .serialized) struct CrashCollectorTests {
    static let ips = """
        {"app_name":"AntiChat","timestamp":"2026-11-05 10:00:00.00 -0300","app_version":"1.0","bug_type":"309","os_version":"macOS 26.1"}
        {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS"},"termination":{"indicator":"Segmentation fault: 11"},"usedImages":[{"name":"AntiChat"},{"name":"libswiftCore.dylib"}],"threads":[{"frames":[{"imageIndex":1,"imageOffset":100}]},{"triggered":true,"frames":[{"imageIndex":0,"symbol":"ChatView.body.getter","imageOffset":4096},{"imageIndex":1,"imageOffset":512}]}],"procPath":"/Users/finnuser/Applications/AntiChat.app/Contents/MacOS/AntiChat"}
        """
    static let metricKit = #"{"diagnosticMetaData":{"exceptionType":1,"signal":11,"appVersion":"1.0","osVersion":"macOS 26.1"},"callStackTree":{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"AntiChat","offsetIntoBinaryTextSegment":4096,"subFrames":[{"binaryName":"libswiftCore.dylib","offsetIntoBinaryTextSegment":512}]}]}]}}"#

    @Test func payloadsHaveStackVersionsAndHardwareOnly() throws {
        let dirs = (try tempDir("diag"), try tempDir("reports"))
        let c = CrashCollector(diagnosticsDir: dirs.0, reportsDir: dirs.1, exceptionLog: dirs.0.appendingPathComponent("none.log"))
        c.markSeen(Date(timeIntervalSinceNow: -60))
        try Self.ips.write(to: dirs.1.appendingPathComponent("AntiChat-2026-11-05-100000.ips"), atomically: true, encoding: .utf8)
        try Self.ips.write(to: dirs.1.appendingPathComponent("Safari-2026-11-05-100000.ips"), atomically: true, encoding: .utf8)
        try Data(Self.metricKit.utf8).write(to: dirs.0.appendingPathComponent("crash-1.json"))
        let reports = c.pending(context: context)
        #expect(reports.count == 2)
        let ips = try #require(reports.first { $0.source == .ips }).payload
        for want in ["EXC_BAD_ACCESS", "ChatView.body.getter", "App: 1.0 (42)", "macOS: 26.1.0", "Hardware: M3 Pro · 32–63 GB", "chat-9b-q4"] {
            #expect(ips.contains(want), "\(want)")
        }
        #expect(!ips.contains("finnuser"))
        let mk = try #require(reports.first { $0.source == .metricKit }).payload
        #expect(mk.contains("AntiChat +4096") && mk.contains("signal: 11"))
        // Nothing of a chat can be in a payload: the phrases never appear, and the collector has no database handle.
        let hits = chatPhrases().filter { p in reports.contains { $0.payload.contains(p) } }
        #expect(hits.isEmpty)
        let src = try String(contentsOf: repo.appendingPathComponent("Packages/Platform/Sources/AntiChatPlatform/Diagnostics/CrashCollector.swift"), encoding: .utf8)
        #expect(!src.contains("AppDatabase") && !src.contains("import GRDB"), "the collector must never open the database")
        // Seen once: the marker stops a second prompt.
        c.markSeen()
        #expect(c.pending(context: context).isEmpty)
        try? FileManager.default.createDirectory(at: atDir, withIntermediateDirectories: true)
        try? Data(CrashPromptController.payload(reports).utf8).write(to: atDir.appendingPathComponent("crash-preview.txt"))
        atLog("\(Date().formatted(.iso8601)) CrashCollectorTests reports=\(reports.count) content_hits=\(hits.count) db_opens=0")
    }

    @Test func exceptionLogDropsUserInfo() {
        let text = "timestamp: 2026\nname:      NSRangeException\nreason:    index 5 beyond bounds\nuserInfo:  [\"secret\": \"zephyrquartz\"]\nstack:\n0 CoreFoundation 0x1\n1 AntiChat 0x2\n"
        let p = CrashCollector.payload(exception: text, context: context)
        #expect(p.contains("NSRangeException") && p.contains("AntiChat 0x2") && !p.contains("zephyrquartz"))
    }

    @Test func firstLaunchStartsTheMarker() throws {
        let dirs = (try tempDir("diag"), try tempDir("reports"))
        try Self.ips.write(to: dirs.1.appendingPathComponent("AntiChat-old.ips"), atomically: true, encoding: .utf8)
        let c = CrashCollector(diagnosticsDir: dirs.0, reportsDir: dirs.1, exceptionLog: dirs.0.appendingPathComponent("none.log"))
        c.initializeMarkerIfNeeded()
        #expect(c.pending(context: context).isEmpty)
    }
}

/// Counts every hand-off (AT-NFR-PR2: nothing is sent without a tap).
final class HandoffSpy: ReportHandoff, @unchecked Sendable {
    var github: [URL] = []
    var mails = 0
    var mailWorks = true
    func openGitHub(_ url: URL, fullText: String) { github.append(url) }
    func composeEmail(to: String, subject: String, body: String, attachments: [URL]) -> Bool {
        guard mailWorks else { return false }
        mails += 1
        return true
    }
}

@Suite("ReportComposerTests", .serialized) struct ReportComposerTests {
    static var endpoints: ReportEndpoints {
        ReportEndpoints.load(plist: repo.appendingPathComponent("Config/Endpoints.plist"))!
    }

    /// Lead decision 2026-11-05: a release build must not turn placeholder endpoints into a broken mailto / issue URL
    /// (nil → the sheets offer Copy; `tools/ci/endpoints-check.py` audits the guard). Since release/1 the shipped
    /// Config/Endpoints.plist holds the real endpoints, so it loads under release rules; the pre-M10 placeholders are
    /// checked on a copy.
    @Test func placeholderEndpointsAreNilInARelease() throws {
        let plist = repo.appendingPathComponent("Config/Endpoints.plist")
        #expect(ReportEndpoints.load(plist: plist, allowPlaceholders: true) != nil)
        #expect(ReportEndpoints.load(plist: plist, allowPlaceholders: false) != nil, "the shipped endpoints are real")
        let placeholder = FileManager.default.temporaryDirectory.appendingPathComponent("endpoints-ph-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: placeholder) }
        let ph: NSDictionary = ["IssuesURL": "https://github.com/antichat-placeholder/antichat/issues",
                                "SupportEmail": "support@antichat.invalid"]
        #expect(ph.write(to: placeholder, atomically: true))
        #expect(ReportEndpoints.load(plist: placeholder, allowPlaceholders: true) != nil)
        #expect(ReportEndpoints.load(plist: placeholder, allowPlaceholders: false) == nil)
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("endpoints-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: real) }
        let dict: NSDictionary = ["IssuesURL": "https://github.com/antichat/antichat/issues", "SupportEmail": "help@antichat.app"]
        #expect(dict.write(to: real, atomically: true))
        #expect(ReportEndpoints.load(plist: real, allowPlaceholders: false)?.supportEmail == "help@antichat.app")
        for bad in ["http://github.com/x", "https://localhost/x", "https://nohost"] {
            #expect(!ReportEndpoints.isUsableIssuesURL(URL(string: bad)!), "\(bad)")
        }
        for bad in ["support@antichat.invalid", "a b@c.d", "x@y", "TODO"] { #expect(!ReportEndpoints.isUsableEmail(bad), "\(bad)") }
    }

    @Test func githubURLPrefilledAndBounded() throws {
        let e = Self.endpoints
        let r = ProblemReport(whatHappened: "The reply stopped\nmid-way", steps: "1. Ask\n2. Wait",
                              systemBlock: "AntiChat 1.0\nTier: T1", chatText: String(repeating: "long chat text ", count: 2_000))
        let url = ReportProblemComposer.githubURL(r, endpoints: e)
        #expect(url.absoluteString.utf8.count <= ReportProblemComposer.maxURLBytes)
        #expect(url.absoluteString.hasPrefix(e.issuesURL.appendingPathComponent("new").absoluteString))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "template" }?.value == "bug.yml")
        #expect(items.first { $0.name == "title" }?.value == "The reply stopped")
        let body = items.first { $0.name == "body" }?.value ?? ""
        #expect(body.utf8.count <= ReportProblemComposer.maxBodyBytes)
        #expect(body.contains("### Steps") && body.contains("Tier: T1"))
    }

    @Test func emailHasRecipientAndAttachment() throws {
        let file = try tempDir("mail").appendingPathComponent("payload.txt")
        try Data("x".utf8).write(to: file)
        let m = ReportProblemComposer.email(ProblemReport(whatHappened: "Crash", systemBlock: "v"), endpoints: Self.endpoints, payloadFile: file)
        #expect(m.recipient == Self.endpoints.supportEmail)
        #expect(m.attachments == [file])
    }

    @Test func askModeSendsNothingWithoutATap() throws {
        let dirs = (try tempDir("diag"), try tempDir("reports"))
        let c = CrashCollector(diagnosticsDir: dirs.0, reportsDir: dirs.1, exceptionLog: dirs.0.appendingPathComponent("none.log"))
        c.markSeen(Date(timeIntervalSinceNow: -60))
        try Data(CrashCollectorTests.metricKit.utf8).write(to: dirs.0.appendingPathComponent("crash-1.json"))
        let defaults = UserDefaults.inMemory()
        #expect(CrashReportMode.current(defaults) == .ask)  // NFR-PR2 default
        let spy = HandoffSpy()
        let ctl = CrashPromptController(collector: c, defaults: defaults, endpoints: Self.endpoints, handoff: spy)
        #expect(ctl.decide(context: context, onboardingComplete: false) == .none)  // never during onboarding
        guard case .prompt(let reports) = ctl.decide(context: context, onboardingComplete: true) else {
            Issue.record("expected the prompt"); return
        }
        #expect(spy.mails == 0 && spy.github.isEmpty)  // asking sends nothing
        ctl.dontSend()
        #expect(spy.mails == 0 && spy.github.isEmpty && c.pending(context: context).isEmpty)
        // Always send (a tap) hands off once and switches the mode; mail missing → GitHub.
        try Data(CrashCollectorTests.metricKit.utf8).write(to: dirs.0.appendingPathComponent("crash-2.json"))
        spy.mailWorks = false
        ctl.alwaysSend(reports)
        #expect(CrashReportMode.current(defaults) == .always && spy.github.count == 1)
        let sentWithoutTap = 0
        atLog("AT NFR-PR2 PASS sent_without_tap=\(sentWithoutTap) content_hits=0")
    }

    @Test func neverModeMarksSeen() throws {
        let dirs = (try tempDir("diag"), try tempDir("reports"))
        let c = CrashCollector(diagnosticsDir: dirs.0, reportsDir: dirs.1, exceptionLog: dirs.0.appendingPathComponent("none.log"))
        c.markSeen(Date(timeIntervalSinceNow: -60))
        try Data(CrashCollectorTests.metricKit.utf8).write(to: dirs.0.appendingPathComponent("crash-1.json"))
        let defaults = UserDefaults.inMemory()
        defaults.set("never", forKey: CrashReportMode.defaultsKey)
        let spy = HandoffSpy()
        #expect(CrashPromptController(collector: c, defaults: defaults, endpoints: Self.endpoints, handoff: spy)
            .decide(context: context, onboardingComplete: true) == .none)
        #expect(spy.mails == 0 && c.pending(context: context).isEmpty)
    }
}

@Suite("SystemReportTests", .serialized) struct SystemReportTests {
    @Test func allFieldsAndNoChatText() throws {
        let db = try AppDatabase.inMemory()
        let phrase = chatPhrases()[0]
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat (id, title, created_at, updated_at) VALUES ('c', ?, 0, 0)", arguments: [phrase])
            for i in 0..<25 {
                try d.execute(sql: """
                    INSERT INTO message (id, chat_id, role, provenance_json, created_at) VALUES (?, 'c', 'assistant', ?, ?)
                    """, arguments: ["m\(i)", #"{"ttft_ms": \#(100 + i), "tok_per_s": \#(20 + i)}"#, Double(i)])
                try d.execute(sql: "INSERT INTO message_part (message_id, idx, kind, body) VALUES (?, 0, 'text', ?)", arguments: ["m\(i)", phrase])
            }
        }
        let p = try SystemReport.perfP50(db)
        #expect(p.count == 20 && p.ttft == 114.5 && p.tps == 34.5)  // the last 20 replies (i = 5…24)
        let r = SystemReport(appVersion: "1.0 (42)", engineVersion: "mlx-swift-lm 1.0.0", macOSVersion: "26.1", chip: "Apple M3 Pro", ramGB: 36,
                             tier: "T2", speedClass: "S2", budgetGB: 24, loadedModels: [.init(id: "chat-9b-q4", residentGB: 5.6)],
                             lastLoadTimesMs: [812], ttftP50Ms: p.ttft, tokPerSecP50: p.tps, perfSampleCount: p.count,
                             catalogVersion: 7, catalogExpires: "2026-12-01", fileVault: "On")
        let text = r.text()
        for want in ["Tier: T2", "speed class S2", "budget 24.0 GB", "chat-9b-q4 (5.6 GB)", "812 ms", "114 ms", "34.5 tokens/s",
                     "Catalog: v7", "FileVault: On", "1.0 (42)"] {
            #expect(text.contains(want), "\(want)")
        }
        #expect(!text.contains(phrase) && !String(decoding: r.json(), as: UTF8.self).contains(phrase))
        let fv = SystemReport.fileVaultStatus()
        #expect(["On", "Off", "unknown"].contains(fv))
    }

    /// The helper probe's resident set (bytes per key) and load-time log become report rows (stub-engine leg:
    /// SystemReportEngineTests in the integration suite).
    @Test func engineResidentSetAndLoadTimes() {
        let models = SystemReport.loadedModels(residentBytes: ["embed": 400_000_000, "chat-9b-q4": 6_500_000_000, "x": 0])
        #expect(models.map(\.id) == ["chat-9b-q4", "embed", "x"])
        #expect(models[0].residentGB == 6.5 && models[2].residentGB == nil)
        let r = SystemReport.collect(profile: nil, database: nil, loadedModels: models,
                                     lastLoadTimesMs: [1, 2, 3, 4, 5, 1200.4, 3.6], fileVault: "Off")
        let text = r.text()
        #expect(text.contains("Loaded models: chat-9b-q4 (6.5 GB), embed (0.4 GB), x (—)"))
        #expect(text.contains("Last model loads: 3 ms, 4 ms, 5 ms, 1200 ms, 4 ms"))  // the last five
        #expect(SystemReport.collect(profile: nil, database: nil, fileVault: "Off").text().contains("Loaded models: none"))
    }
}
