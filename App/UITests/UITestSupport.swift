// Shared UI-test launch helper (M1.T02; docs/prd/M1.md convention 3, test-strategy §4.2). Every UI test launches
// AntiChat with its own throwaway container, so UI tests never touch the dev container:
//   -ANTICHAT_DEV_CONTAINER $TMPDIR/antichat-uitest-<uuid>
import AppKit
import Foundation
import XCTest

extension XCUIApplication {
    /// The AntiChat app as a real foreground app. Every UI test builds its app through this: a launch with a
    /// throwaway `-ANTICHAT_DEV_CONTAINER` would otherwise turn BackgroundRun on (activation policy `.prohibited`,
    /// concealed windows), which XCUITest cannot drive (Q-015 catch-up).
    static func foreground() -> XCUIApplication {
        PasteboardGuard.install()
        let app = AntiChatUIApp()
        app.launchEnvironment["ANTICHAT_BACKGROUND"] = "0"
        return app
    }
}

/// Resolves the shorthand script values the suites pass at launch (Q-015 catch-up): the app reads
/// `-UseScriptedEngine <path>` as a file path, so `basic` / `YES` / a repo-relative path fell back to the real XPC
/// engine (no model installed → no reply).
final class AntiChatUIApp: XCUIApplication {
    override func launch() {
        PasteboardGuard.install()
        launchArguments = Self.freshDefaultsSuite(Self.resolve(launchArguments))
        // The AntiChatApplication hit-test workaround's A/B switch (`TEST_RUNNER_ANTICHAT_AX_HIT_REFINE=0`).
        if let v = ProcessInfo.processInfo.environment["ANTICHAT_AX_HIT_REFINE"] { launchEnvironment["ANTICHAT_AX_HIT_REFINE"] = v }
        super.launch()
        Self.current = self
    }

    /// The app the running test launched last; a failing assertion attaches its UI tree (PasteboardGuard).
    nonisolated(unsafe) static weak var current: AntiChatUIApp?

    /// Suites named with `-DefaultsSuite` live in ~/Library/Preferences (the app is another process, and a relaunch
    /// inside a test must keep them), so a test saw the settings an earlier run left behind. Each test starts its
    /// suites empty; a relaunch inside the test keeps them. The app empties the suite (`-FreshDefaultsSuite YES`): this
    /// runner is sandboxed, its own UserDefaults reach only its container's prefs. Names are stable
    /// `com.antichat.uitest.<name>`, never a UUID or pid, which left one plist per run behind (fix/test-plist-hygiene;
    /// `TestPlistHygieneTests` keeps it so).
    nonisolated(unsafe) static var suitesStarted: Set<String> = []
    static func freshDefaultsSuite(_ args: [String]) -> [String] {
        guard let i = args.firstIndex(of: "-DefaultsSuite"), i + 1 < args.count, !args.contains("-FreshDefaultsSuite") else {
            return args
        }
        let suite = args[i + 1]
        guard suite.hasPrefix("com.antichat.uitest."), !suitesStarted.contains(suite) else { return args }
        suitesStarted.insert(suite)
        return args + ["-FreshDefaultsSuite", "YES"]
    }

    static func turnScript(_ line: String) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString).jsonl")
        try? Data((line + "\n").utf8).write(to: url)
        return url.path
    }

    static func resolve(_ args: [String]) -> [String] {
        var out = args
        for i in out.indices.dropLast() where out[i] == "-UseScriptedEngine" {
            let v = out[i + 1]
            if v == "YES", out.contains("-UseScriptedVideoEngine") {
                // "the scripted engine writes the create_video call" (VideoPlanTests & co.): a one-call turn on a
                // tool-capable chat model (the starter is chat-only, D-023).
                out[i + 1] = Self.turnScript(#"{"t":"toolCallDone","id":"call_1","name":"create_video","args":"{\"prompt\":\"waves rolling onto a beach at dusk\"}","delayMs":1}"#)
                if !out.contains("-ChatModel") { out += ["-ChatModel", "chat-9b-q4"] }
            } else if v == "basic" || v == "YES" {
                out[i + 1] = TurnApp.script("basic.jsonl")
            } else if !v.hasPrefix("/"), v.contains("/") {
                out[i + 1] = TurnApp.repoRoot.appendingPathComponent(v).path
            } else if !v.hasPrefix("/"), v.hasSuffix(".jsonl") {
                out[i + 1] = TurnApp.script(v)
            } else if !v.hasPrefix("/"), !v.contains("."), v.uppercased() != "NO" {
                out[i + 1] = TurnApp.script(v + ".jsonl")  // a bare script name ("memory-remember")
            }
        }
        if let i = out.firstIndex(of: "-UseScriptedEngine"), i + 1 < out.count, out[i + 1].uppercased() != "NO" {
            let path = out[i + 1]
            if !FileManager.default.fileExists(atPath: path) {
                // A missing script silently fell back to the XPC engine, i.e. a real model on the GPU.
                XCTFail("missing ScriptedEngine script \(path)")
                out[i + 1] = TurnApp.script("basic.jsonl")
            } else if !out.contains("-ChatModel"),
                      let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains("toolCallDone") {
                // A fresh container's chat model is the chat-only starter, which is offered no tools (D-023 a): a
                // scripted tool call needs a tool-capable chat slot.
                out += ["-ChatModel", "chat-9b-q4"]
            }
        }
        // Repo-relative fixture paths (-UseScriptedVoice fixtures/voice/…): the app resolves them against its own cwd.
        for i in out.indices where out[i].hasPrefix("fixtures/") || out[i].hasPrefix("tools/fixtures/") {
            out[i] = TurnApp.repoRoot.appendingPathComponent(out[i]).path
        }
        return out
    }
}

extension XCUIApplication {

    /// An app configured with a fresh per-run container plus `arguments` (debug launch options, convention 10).
    static func antichat(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication.foreground()
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("antichat-uitest-\(UUID().uuidString)", isDirectory: true)
        app.launchArguments = ["-ANTICHAT_DEV_CONTAINER", container.path] + arguments
        // XCUITest drives the real foreground app (accessibility + HID events): opt out of the background run a dev
        // container would otherwise turn on (BackgroundRun). These suites stay pending while XCUITest is blocked (Q-015).
        app.launchEnvironment["ANTICHAT_BACKGROUND"] = "0"
        // M9.T03: the launched app writes its pid here (DEBUG), so tools/ci/a11y-axstate reads this exact process.
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("a11y-axstate-\(UUID().uuidString).pid")
        app.launchEnvironment["ANTICHAT_A11Y_PIDFILE"] = pidFile.path
        A11yPidFile.path = pidFile.path
        return app
    }

    /// The main chat window. SwiftUI names it `main-AppWindow-<n>` and titles it after the open chat ("New chat"),
    /// so `windows["AntiChat"]` never matches (Q-015 catch-up).
    @MainActor var mainWindow: XCUIElement {
        windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main-'")).firstMatch
    }
}

/// Several suites paste through the general pasteboard (the owner's clipboard). This puts the owner's clipboard back
/// after every test that changed it (Q-015 catch-up: the Mac is in use while the suites run).
final class PasteboardGuard: NSObject, XCTestObservation {
    nonisolated(unsafe) private static var shared: PasteboardGuard?
    private var saved: [[NSPasteboard.PasteboardType: Data]] = []
    private var changeCount = 0

    static func install() {
        guard shared == nil else { return }
        let g = PasteboardGuard()
        g.snapshot()
        shared = g
        XCTestObservationCenter.shared.addTestObserver(g)
    }

    private func snapshot() {
        let pb = NSPasteboard.general
        saved = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        changeCount = pb.changeCount
    }

    /// Between tests the clipboard is the owner's: take a fresh copy if they changed it.
    private var treeAttached = false

    /// The first failure of a test attaches the app's UI tree: plain assertion failures get none from XCTest, and
    /// triage needs to see what was on screen (Q-015 catch-up).
    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        guard !treeAttached, let app = AntiChatUIApp.current, app.state == .runningForeground else { return }
        treeAttached = true
        let tree = app.debugDescription
        print("UITREE-BEGIN \(testCase.name)\n\(tree)\nUITREE-END")  // readable while the run is still going
        let a = XCTAttachment(string: tree)
        a.name = "App UI hierarchy (first failure)"
        a.lifetime = .deleteOnSuccess
        testCase.add(a)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        treeAttached = false
        AntiChatUIApp.suitesStarted = []
        if NSPasteboard.general.changeCount != changeCount { snapshot() }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        // An app left running (a quit that asks "Cancel or wait" while a job runs, a hung quit) made XCUITest fail to
        // terminate it at the next launch and broke every later test in the run: end it here (Q-015 catch-up).
        if let app = AntiChatUIApp.current, app.state != .notRunning, let pid = app.processID {
            kill(pid, SIGKILL)
            _ = app.wait(for: .notRunning, timeout: 15)  // let XCUITest see it go before the next launch
        }
        AntiChatUIApp.current = nil
        let pb = NSPasteboard.general
        guard pb.changeCount != changeCount else { return }
        pb.clearContents()
        let items = saved.map { d -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in d { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        changeCount = pb.changeCount
    }
}

extension XCUIElement {
    /// `value` as text: a checkbox or switch reports an NSNumber (0/1), not a String (Q-015 catch-up).
    var stringValue: String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}

extension XCUIElement {
    /// What the element shows: SwiftUI exposes some texts (selectable or long text, e.g. `assistantText`,
    /// `interruptedReason`) as the AX value with an empty label (Q-015 catch-up).
    var displayText: String {
        let l = label
        return l.isEmpty ? stringValue : l
    }

    /// `displayText` from one snapshot, nil when the element is gone (Q-015 r4): reading `label` of an element that
    /// vanished between `exists` and the read fails the test ("No matches found"); a snapshot throws instead.
    var shownText: String? {
        guard let s = try? snapshot() else { return nil }
        return s.label.isEmpty ? (s.value as? String ?? "") : s.label
    }
}

extension XCUIElement {
    /// A Form DisclosureGroup toggles on its triangle, not on its label's centre (Q-015 catch-up).
    func clickDisclosure() {
        let before = stringValue
        // Q-015 r5: on a wide row (637 pt, Privacy's network activity) 6 % is ~38 pt in, on the label's text, which
        // does not toggle; the chevron is the first ~16 pt. Click 8 pt in (or 6 % on a narrow row, as before).
        let dx = frame.width > 0 ? min(0.06, 8 / frame.width) : 0.06
        coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).click()
        // Q-015 r2: the offset missed the triangle on a narrow row (value stayed 0); the element's own press toggles it.
        // Q-015 r3: the value updates a moment after the click; read too early it still said 0, and the fallback press
        // closed the group the first click had just opened. Wait for the change before falling back.
        let end = Date().addingTimeInterval(1.5)
        while stringValue == before, Date() < end { Thread.sleep(forTimeInterval: 0.1) }
        if stringValue == before, elementType == .disclosureTriangle { click() }
    }
}

extension XCUIApplication {
    /// This test's app process (other worktrees' test hosts share the bundle id and must never be touched).
    var processID: pid_t? {
        guard let n = value(forKey: "processID") as? NSNumber, n.int32Value > 0 else { return nil }
        return n.int32Value
    }
}

extension XCUIElement {
    /// Scrolls this scroll view down until `target` is on screen (a Form builds rows below the fold lazily, so
    /// XCUITest cannot see them before; Q-015 catch-up).
    @discardableResult
    func scrollUntilVisible(_ target: XCUIElement, maxSteps: Int = 15) -> Bool {
        for _ in 0..<maxSteps {
            if target.exists, target.isHittable { return true }
            scroll(byDeltaX: 0, deltaY: -300)
        }
        return target.exists
    }
}

extension XCUIElement {
    /// Clicks a control inside a reply (plan / approval / job cards): SwiftUI's transcript reports those controls as
    /// "Not hittable" to XCUITest's accessibility hit test although a mouse click lands (Q-015 r2, HitDiag: the
    /// coordinate click started the job). The click is still a real mouse click at the control's centre.
    func clickReliably() {
        if isHittable { click() } else { coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }
    }
}

extension XCUIApplication {
    /// Starts the video plan card's job: an explicit request on AC power counts down and starts by itself (R-290 AC2),
    /// so clicking Start raced the countdown and hit a card that had just gone (Q-015 r2). Start only when it waits.
    @MainActor func startVideoPlan(file: StaticString = #filePath, line: UInt = #line) {
        let any = descendants(matching: .any)
        let start = any.matching(identifier: "videoPlan.start").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 30), "plan card", file: file, line: line)
        if !any.matching(identifier: "videoPlan.countdown").firstMatch.exists { start.clickReliably() }
    }
}

/// Connections in a fresh container (Q-015 r2): `-ScriptedMCP` only answers for connections the user added, so the
/// suites whose script calls `team_chat_*` add "Team Chat" through Settings first, as the user does (journey 12).
enum MCPUI {
    @MainActor static func addTeamChat(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let any = app.descendants(matching: .any)
        app.typeKey(",", modifierFlags: .command)
        any.matching(identifier: "settings.nav.connections").firstMatch.click()
        app.buttons["connections.add"].click()
        let url = app.textFields["connections.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5), "add sheet", file: file, line: line)
        url.click(); url.typeText("https://chat.example/mcp")
        let name = app.textFields["connections.name"]
        name.click(); name.typeText("Team Chat")
        app.buttons["connections.check"].click()
        XCTAssertTrue(any.matching(identifier: "mcpConsent").firstMatch.waitForExistence(timeout: 10), "consent sheet", file: file, line: line)
        app.buttons["mcpConsent.allow"].click()
        let added = any.matching(NSPredicate(format: "identifier BEGINSWITH 'connectionRow.'")).firstMatch.waitForExistence(timeout: 10)
        let error = any.matching(identifier: "connections.error").firstMatch
        XCTAssertTrue(added, "Team Chat added: \(error.exists ? error.displayText : "no error shown")", file: file, line: line)
        app.windows.containing(.any, identifier: "settings.root").firstMatch.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.mainWindow.waitForExistence(timeout: 5), file: file, line: line)
    }
}

/// Processes for the crash legs (Q-015 r3): `pkill` from the test runner exits 3 ("internal error": the runner is
/// sandboxed and cannot list other processes through sysctl), so the app is killed by its own pid and helpers are found
/// by executable path through libproc.
enum TestProcesses {
    /// Pids whose executable is exactly `path`.
    static func pids(executable path: String) -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(n) * 2)
        let got = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: 4096)
        return all.prefix(Int(got)).filter { pid in
            pid > 0 && proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 && String(cString: buf) == path
        }
    }

    /// SIGKILL to `pids`; true when there was at least one and every kill succeeded.
    @discardableResult static func kill9(_ pids: [pid_t]) -> Bool {
        !pids.isEmpty && pids.allSatisfy { Darwin.kill($0, SIGKILL) == 0 }
    }
}

/// Q-015 r5: AX attributes XCUITest does not surface — a slider's `AXValueDescription` (what VoiceOver speaks for
/// SwiftUI's `.accessibilityValue`; XCUIElement.value is the raw AXValue) and `AXHelp` (the `.help` tooltip). The
/// sandboxed runner gets nothing from the Accessibility API, so the app's DEBUG AXAttributeProbe reads them from its own
/// accessibility objects and logs them; the test reads that log. The attribute assistive apps read, not a stand-in.
enum AXRead {
    enum Attribute: Int { case valueDescription = 1, help = 2 }

    /// Turns the probe on for `ids` (before `launch()`); returns its log.
    static func enable(_ app: XCUIApplication, ids: [String]) -> URL {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("ax-attrs-\(UUID().uuidString).log")
        app.launchEnvironment["ANTICHAT_AX_ATTR_LOG"] = log.path
        app.launchEnvironment["ANTICHAT_AX_ATTR_IDS"] = ids.joined(separator: ",")
        return log
    }

    /// The newest logged `attribute` of `identifier` (nil = not logged yet).
    static func latest(_ log: URL, identifier: String, _ attribute: Attribute) -> String? {
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true)
        guard let l = lines.last(where: { $0.hasPrefix(identifier + "\t") }) else { return nil }
        let cols = l.split(separator: "\t", omittingEmptySubsequences: false)
        return cols.count > attribute.rawValue ? String(cols[attribute.rawValue]) : nil
    }

    /// Polls `latest` until it equals `expected` (or `timeout`); returns the last value read.
    static func wait(_ log: URL, identifier: String, _ attribute: Attribute, equals expected: String, timeout: TimeInterval = 5) -> String? {
        let end = Date().addingTimeInterval(timeout)
        var last = latest(log, identifier: identifier, attribute)
        while last != expected, Date() < end {
            Thread.sleep(forTimeInterval: 0.2)
            last = latest(log, identifier: identifier, attribute)
        }
        return last
    }
}


/// The pid file of the app launched last through `XCUIApplication.antichat(_:)` (M9.T03, AccessibilityAuditTests).
enum A11yPidFile {
    nonisolated(unsafe) static var path: String?
}
