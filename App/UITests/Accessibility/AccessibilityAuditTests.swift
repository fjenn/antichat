// AT-223 part 3 / AT-NFR-A6 (M9.T03 step 1): performAccessibilityAudit(for: .all) on every primary screen and each
// Settings section; nothing is ignored except tools/a11y/audit-ignores.yml entries (each with reason + reviewer).
import AppKit
import ApplicationServices
import XCTest

final class AccessibilityAuditTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// Ignore-list entries from tools/a11y/audit-ignores.yml (`- element:` + `issue:` lines; empty by default). An
    /// entry covers the element with that identifier and everything inside its frame (AppKit's window buttons carry
    /// unnamed child groups), for that audit type only. `scope: sameFrame` narrows it to an element with exactly that
    /// element's frame (the SwiftUI sidebar column group around the `sidebar` outline, not the rows inside it).
    static let ignored: [(element: String, issue: String, sameFrame: Bool)] = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "tools/a11y/audit-ignores.yml")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var out: [(String, String, Bool)] = []
        for l in text.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- element:") { out.append((String(t.dropFirst(10)).trimmingCharacters(in: .whitespaces), "", false)) }
            if t.hasPrefix("issue:"), !out.isEmpty { out[out.count - 1].1 = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            if t == "scope: sameFrame", !out.isEmpty { out[out.count - 1].2 = true }
        }
        return out.filter { !$0.1.isEmpty }
    }()

    static let auditTypes: [String: XCUIAccessibilityAuditType] = [
        "contrast": .contrast, "elementDetection": .elementDetection, "hitRegion": .hitRegion,
        "sufficientElementDescription": .sufficientElementDescription,
        "action": .action, "parentChild": .parentChild,
    ]

    func audit(_ app: XCUIApplication, _ screen: String) throws { try Self.audit(app, screen) }

    /// What the app's accessibility tree holds right now, read with the AX API from the test runner: the
    /// labels-hidden switches in one window (role AXCheckBox, subrole AXToggle: SwiftUI's thin element; a switch with
    /// its label shown is subrole AXSwitch and has no issue), on or off screen, and whether the app's focused element
    /// is a text field. nil when the AX API is not available to the runner.
    struct AXState { var switches: Int; var focusedField: Bool; var focusedRole: String }

    /// The same facts through XCUITest when the runner is not trusted for the AX API (the default; a TCC grant is the
    /// owner's call). Switches: check boxes in the window's tree, on or off screen, whose label is their own
    /// description — SwiftUI's labels-hidden switch (AXToggle) carries its label as AXDescription, while a switch
    /// with its label shown names it through a separate title element and has an empty `label` here, as do plain
    /// check boxes with a visible title. Focus: the element XCUITest reports with keyboard focus, when it is a text
    /// field, search field or combo box.
    static func xcuiState(_ app: XCUIApplication, windowIdentifierPrefix: String) -> AXState {
        let root: XCUIElement = windowIdentifierPrefix.isEmpty
            ? app : app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", windowIdentifierPrefix)).firstMatch
        let switches = root.descendants(matching: .checkBox).allElementsBoundByIndex.filter { $0.exists && !$0.label.isEmpty }.count
        // Asked per field type: on `.any` the key window itself matches `hasKeyboardFocus` first.
        var role = "none"
        for type in [XCUIElement.ElementType.textField, .searchField, .comboBox]
        where app.descendants(matching: type).matching(NSPredicate(format: "hasKeyboardFocus == true")).count > 0 {
            role = "XCUI type \(type.rawValue)"
            break
        }
        // A focused field the type queries missed: the element description XCUITest prints for a snapshot.
        if role == "none" {
            for type in [XCUIElement.ElementType.textField, .searchField]
            where root.descendants(matching: type).allElementsBoundByIndex.contains(where: { $0.debugDescription.contains("Keyboard Focused") }) {
                role = "XCUI type \(type.rawValue) (snapshot)"
                break
            }
        }
        return AXState(switches: switches, focusedField: role != "none", focusedRole: role)
    }

    /// Asks tools/ci/a11y-axstate (started outside the runner by tools/ci/with-mcp-ref.sh) through the runner's
    /// temporary directory; nil when no helper answers within 5 s.
    static func helperState(windowIdentifierPrefix: String)
        -> (state: AXState, progress: Int, quickPanelClear: Int, outOfTree: [String], roles: String)? {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        let id = UUID().uuidString
        let req = dir.appendingPathComponent("a11y-axstate-\(id).req")
        let resp = dir.appendingPathComponent("a11y-axstate-\(id).resp")
        let request = windowIdentifierPrefix + "\n" + (A11yPidFile.path ?? "")
        guard (try? request.write(to: req, atomically: true, encoding: .utf8)) != nil else { return nil }
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let data = try? Data(contentsOf: resp),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil {
                try? FileManager.default.removeItem(at: resp)
                let state = AXState(switches: json["switches"] as? Int ?? 0, focusedField: json["focusedField"] as? Bool ?? false,
                                    focusedRole: json["focused"] as? String ?? "none")
                return (state, json["progressIndicators"] as? Int ?? 0, json["quickPanelClear"] as? Int ?? 0,
                        json["outOfTree"] as? [String] ?? [], json["roles"] as? String ?? "")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: req)
        return nil
    }

    /// A crash dialog or system alert on screen makes every pixel measurement meaningless (Q-015 r5/r6: "AntiChat quit
    /// unexpectedly" sat over the window for whole runs). Checked before each audit from the window server's list.
    static func contaminatingWindows() -> [String] {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w in
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let name = w[kCGWindowName as String] as? String ?? ""
            let bad = ["Problem Reporter", "UserNotificationCenter"].contains(owner) || name.localizedCaseInsensitiveContains("quit unexpectedly")
            return bad ? "\(owner) '\(name)'" : nil
        }
    }

    static func axState(windowIdentifierPrefix: String) -> AXState? {
        guard AXIsProcessTrusted() else { return nil }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "app.antichat.AntiChat.dev")
        guard let target = running.max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }) else { return nil }
        let appEl = AXUIElementCreateApplication(target.processIdentifier)
        func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
        }
        var focusedRole = "none"
        var focusedField = false
        if let f = attr(appEl, kAXFocusedUIElementAttribute) {
            let e = f as! AXUIElement
            let role = attr(e, kAXRoleAttribute) as? String ?? "?"
            let sub = attr(e, kAXSubroleAttribute) as? String ?? ""
            focusedRole = sub.isEmpty ? role : "\(role)/\(sub)"
            focusedField = role == kAXTextFieldRole || role == kAXComboBoxRole
        }
        var switches = 0
        let windows = (attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in windows where ((attr(w, kAXIdentifierAttribute) as? String) ?? "").hasPrefix(windowIdentifierPrefix) {
            func walk(_ e: AXUIElement, _ depth: Int) {
                if (attr(e, kAXRoleAttribute) as? String) == kAXCheckBoxRole, (attr(e, kAXSubroleAttribute) as? String) == "AXToggle" {
                    switches += 1
                }
                guard depth < 80 else { return }
                for k in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(k, depth + 1) }
            }
            walk(w, 0)
        }
        return AXState(switches: switches, focusedField: focusedField, focusedRole: focusedRole)
    }

    /// Contrast results deferred because the element was cut by a scroll view's visible edge (S-21). Nothing is
    /// dropped: each deferred element must later be audited wholly inside the visible area with no contrast issue,
    /// at another scroll position, or `finish` fails the test. Keyed by identifier, else the element's text.
    /// The audit calls its handler synchronously on this thread, one issue at a time.
    final class ClippedContrast: @unchecked Sendable {
        var pending: [String: String] = [:]  // key → the deferred failure message
        var cleared: Set<String> = []

        static func key(_ e: XCUIElement) -> String {
            if !e.identifier.isEmpty { return "id:\(e.identifier)" }
            let text = (e.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? e.label
            return "text:\(text)"
        }

        /// Texts already measured whole and passing at an earlier position (a row is often whole at the top of a
        /// section and cut only after a page scroll).
        var passedWhole: Set<String> = []

        /// After an audit at one position: every text wholly inside `clip` with no contrast issue has passed; a
        /// pending element clears when it is one of them now or was one at an earlier position.
        func settle(in root: XCUIElement, clip: CGRect, contrastKeys: Set<String>) {
            for t in root.staticTexts.allElementsBoundByIndex where t.exists && clip.contains(t.frame) {
                let key = Self.key(t)
                if !contrastKeys.contains(key) { passedWhole.insert(key) }
            }
            for key in pending.keys where passedWhole.contains(key) { cleared.insert(key) }
            for key in pending.keys where !cleared.contains(key) && !contrastKeys.contains(key) {
                let e: XCUIElement
                if key.hasPrefix("id:") {
                    e = root.descendants(matching: .any)[String(key.dropFirst(3))]
                } else {
                    let text = String(key.dropFirst(5))
                    e = root.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", text, text)).firstMatch
                }
                if e.exists, clip.contains(e.frame) { cleared.insert(key) }
            }
        }

        /// Every deferred element was measured whole somewhere and passed; otherwise its deferred failure is reported.
        func finish() {
            for (key, message) in pending.sorted(by: { $0.key < $1.key }) where !cleared.contains(key) {
                XCTFail("\(message) (cut by the scroll view at that position, and never audited whole and passing)")
            }
        }
    }

    /// The audit with the ignore list, for any suite (FileActionsTests too, Q-015 r4). With `clip`, a contrast issue
    /// on an element not wholly inside `clip` (the visible area of the scrolled content) is deferred to `clipped`
    /// instead of failing here: its pixels outside the window are the desktop, not our UI.
    ///
    /// With `switchesIn`, element-less "Parent/Child mismatch" issues are counted instead of failing one by one, and
    /// their number must lie in [switches, attributable] (A-M9-T03b, lead decision 2026-11-11), all counted from the
    /// app's exact pid: at least one per SwiftUI labels-hidden `.switch` Toggle in that window's tree (each reliably
    /// produces one: tools/a11y/repros/labels-hidden-switch-parentchild.swift), and at most the total of system-owned
    /// sources we can name — switches + a focused text field + AppKit-backed progress indicators + the quick-panel
    /// recorder's orphaned clear button (`labelsHiddenSwitch`, `progressIndicator`, `quickPanelRecorderClear` in
    /// tools/a11y/audit-ignores.yml). The audit does not report every non-switch source every time (a15: a focused
    /// field and the recorder's clear button together gave one issue; Voice's level meter gave none), so the upper
    /// bound is not an equality. Fewer than the switches, or any issue beyond the attributable total, fails: every
    /// element-less issue is explained by an AppKit/SwiftUI-owned element, and our own code adds none.
    static func audit(_ app: XCUIApplication, _ screen: String, clip: CGRect? = nil,
                      clipped: ClippedContrast? = nil, root: XCUIElement? = nil, switchesIn: String? = nil) throws {
        let dialogs = contaminatingWindows()
        if !dialogs.isEmpty {
            XCTFail("\(screen): not audited, the screen is contaminated by \(dialogs.joined(separator: ", ")) (close it and re-run)")
            return
        }
        let covers: [(CGRect, XCUIAccessibilityAuditType, Bool)] = Self.ignored.flatMap { entry in
            app.descendants(matching: .any).matching(identifier: entry.element).allElementsBoundByIndex
                .compactMap { e in Self.auditTypes[entry.issue].map { (e.frame.insetBy(dx: -0.5, dy: -0.5), $0, entry.sameFrame) } }
        }
        final class Keys: @unchecked Sendable { var set: Set<String> = [] }  // filled by the synchronous handler
        let contrastKeys = Keys()
        final class Count: @unchecked Sendable { var n = 0 }
        let contrastFailed = Count()  // contrast failures reported in this audit (for the evidence screenshot)
        let elementless = Count()
        try app.performAccessibilityAudit(for: .all) { issue in
            let id = issue.element?.identifier ?? ""
            let frame = issue.element?.frame ?? .null
            let skip = covers.contains { c in
                guard c.1.contains(issue.auditType), !frame.isNull, c.0.contains(frame) else { return false }
                return !c.2 || frame.insetBy(dx: -1, dy: -1).contains(c.0.insetBy(dx: 0.5, dy: 0.5))  // sameFrame: ±1 pt
            }
            // The element's type, frame and label: most offenders have no identifier, so `[id]` alone was untriageable.
            let what = issue.element.map { "type=\($0.elementType.rawValue) frame=\($0.frame) label='\($0.label)'" } ?? "no element"
            let message = "\(screen): \(issue.compactDescription) [\(id)] \(what) — \(issue.detailedDescription)"
            // `disabledSettingsRowLabel` (tools/a11y/audit-ignores.yml, signed): a disabled Settings row's label is an
            // inactive component (WCAG 1.4.3); SettingsRow marks it disabled, so it reports isEnabled false. Contrast only.
            if issue.auditType == .contrast, screen.hasPrefix("S-21"), let e = issue.element,
               e.elementType == .staticText, !e.isEnabled {
                return true
            }
            // A signed ignore entry covers the element wherever it is: a cut element was deferred before the ignore
            // list was consulted, so `finish` failed it although the same element whole was skipped.
            if issue.auditType == .contrast, !skip, let e = issue.element {
                let key = ClippedContrast.key(e)
                contrastKeys.set.insert(key)
                if let clip, let clipped, !frame.isNull, !clip.contains(frame) {
                    if clipped.pending[key] == nil { clipped.pending[key] = message }
                    return true  // deferred, not dropped: `finish` fails it unless it passes whole elsewhere
                }
            }
            if issue.auditType == .parentChild, issue.element == nil, switchesIn != nil {
                elementless.n += 1
                return true  // counted; checked against the visible switches below
            }
            if !skip { XCTFail(message); if issue.auditType == .contrast { contrastFailed.n += 1 } }
            return true  // reported above (one failure per issue, not an abort)
        }
        if let switchesIn {
            // Exact facts from the Accessibility API: the a11y-axstate helper outside the sandboxed runner first, the
            // runner's own AX access when it is trusted, else XCUITest's view (which can miss focus changes).
            let helper = helperState(windowIdentifierPrefix: switchesIn)
            let ax = helper?.state ?? axState(windowIdentifierPrefix: switchesIn) ?? xcuiState(app, windowIdentifierPrefix: switchesIn)
            let switches = ax.switches
            let focusedField = ax.focusedField ? 1 : 0
            // `progressIndicator` and `quickPanelRecorderClear` (audit-ignores.yml): one element-less issue per AppKit-backed
            // progress indicator, and one for the quick-panel hotkey recorder's orphaned clear button while it is in the tree.
            let window = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH %@", switchesIn)).firstMatch
            let progress = helper?.progress
                ?? window.descendants(matching: .progressIndicator).count + window.descendants(matching: .activityIndicator).count
            let quickPanel = helper?.quickPanelClear ?? 0
            let attributable = switches + focusedField + progress + quickPanel
            if elementless.n < switches || elementless.n > attributable {
                XCTFail("\(screen): \(elementless.n) element-less Parent/Child mismatch issue(s), expected \(switches)...\(attributable) "
                        + "(min: \(switches) labels-hidden switch(es) in the window tree; max adds \(focusedField) focused text field + "
                        + "\(progress) progress indicator(s) + \(quickPanel) quick-panel recorder clear button; focused: \(ax.focusedRole); "
                        + "source: \(helper == nil ? "runner" : "a11y-axstate"); out of tree: \(helper?.outOfTree.joined(separator: " | ") ?? "n/a"); roles: \(helper?.roles ?? "n/a"))")
            }
        }
        if contrastFailed.n > 0 {  // M9.T03: the screen as audited, to measure the failing text's real contrast
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(screen) contrast"
            shot.lifetime = .keepAlways
            XCTContext.runActivity(named: "\(screen) contrast screenshot") { $0.add(shot) }
        }
        if let clip, let clipped, let root { clipped.settle(in: root, clip: clip, contrastKeys: contrastKeys.set) }
    }

    @MainActor func testNewChatAndChat() throws {
        let app = A11y.launch()
        try audit(app, "S-05")
        A11y.sendOneTurn(app)
        try audit(app, "S-08")
    }

    @MainActor func testEvilChat() throws {
        let app = A11y.launch()
        app.typeKey("e", modifierFlags: [.command, .shift])
        try audit(app, "S-06")
    }

    @MainActor func testPaletteAndShortcuts() throws {
        let app = A11y.launch()
        app.typeKey("k", modifierFlags: .command)
        try Self.audit(app, "S-18", switchesIn: "main-")
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey("/", modifierFlags: .command)
        try audit(app, "S-22")
    }

    @MainActor func testEverySettingsSection() throws {
        let app = A11y.launch()
        // S-21 is the Settings window alone. The chat window is closed once Settings is open: left behind it (Q-015 r3)
        // or minimised (r5), the audit still walked it and measured its text through the Settings window or the
        // desktop. S-05/S-08 audit the chat window.
        let chat = app.mainWindow
        app.typeKey(",", modifierFlags: .command)
        let settings = app.windows.containing(.any, identifier: "settings.root").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        chat.buttons["_XCUI:CloseWindow"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for nav in settings.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.nav.'"))
            .allElementsBoundByIndex {
            nav.click()
            // Every position of the section: the rows below the window's edge are audited once scrolled into it.
            // A row cut by the scroll view's edge has pixels outside the window (the desktop), so its contrast result
            // is deferred, not dropped: `clipped.finish()` fails the test unless the same row was audited wholly
            // inside the visible area, with no contrast issue, at another position (A-M9-T03a, PRD-AMENDMENTS).
            let section = String(nav.identifier.dropFirst("settings.nav.".count))
            let detail = settings.scrollViews["settings.detail.\(section)"]
            let clipped = ClippedContrast()
            defer { clipped.finish() }
            var page = 0
            while true {
                let clip = detail.exists ? detail.frame.intersection(settings.frame) : settings.frame
                try Self.audit(app, "S-21 \(nav.identifier)" + (page == 0 ? "" : " (scrolled \(page))"),
                               clip: clip, clipped: clipped, root: settings, switchesIn: "com_apple_SwiftUI_Settings_window")
                guard detail.exists, page < 12 else { break }
                let probe = detail.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'settings.row.'"))
                    .firstMatch
                let before = probe.exists ? probe.frame.minY : .nan
                detail.scroll(byDeltaX: 0, deltaY: -(detail.frame.height - 60))  // a page, keeping 60 pt of overlap
                if !probe.exists || probe.frame.minY == before { break }  // at the bottom: nothing moved
                page += 1
            }
        }
    }

    /// Evidence for the count-matched `labelsHiddenSwitch` rule (tools/a11y/repros/labels-hidden-switch-parentchild.swift):
    /// audits the standalone repro app with several switch / field combinations and records the element-less
    /// parentChild count of each. Runs only with A11Y_REPRO_APP set (the repro bundle's path); skipped otherwise.
    @MainActor func testReproLabelsHiddenSwitch() throws {
        guard let path = ProcessInfo.processInfo.environment["A11Y_REPRO_APP"] else {
            throw XCTSkip("A11Y_REPRO_APP not set (tools/a11y/repros/make-repro-app.sh)")
        }
        final class Count: @unchecked Sendable { var n = 0 }
        for args in [["switches", "0"], ["switches", "1"], ["switches", "3"], ["switches", "5"], ["shown", "3"],
                     ["field", "1"], ["switches", "2", "field", "1"], ["collapsed", "3"],
                     ["progress", "3"], ["chart", "1"]] {
            let app = XCUIApplication(url: URL(fileURLWithPath: path))
            app.launchArguments = args
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
            let count = Count()
            try app.performAccessibilityAudit(for: .parentChild) { issue in
                if issue.element == nil { count.n += 1 }
                return true
            }
            // The test's own counting, checked here against the audit: the XCUI fallback's switches + focused field.
            let state = Self.xcuiState(app, windowIdentifierPrefix: "")
            let line = "repro \(args.joined(separator: " ")): element-less parentChild = \(count.n); "
                + "xcui switches \(state.switches) + focused field \(state.focusedField ? 1 : 0) (\(state.focusedRole))"
            print(line)
            XCTContext.runActivity(named: line) { _ in }
            app.terminate()
        }
    }

    @MainActor func testOnboarding() throws {
        // Enough free disk for the default selection (the fake-disk seam), so Continue works as designed and the test
        // reaches steps 3 and 4: on a nearly full Mac it stayed on step 2 and audited it three times.
        let app = XCUIApplication.antichat(["-ApplePersistenceIgnoreState", "YES", "-ResetOnboarding", "YES", "-OfflineOnly", "YES",
                                            "-FakeFreeDiskGB", "2000"])
        app.launch()
        for step in 1...4 {
            // The step at rest: Return starts a 0.32 s crossfade, and an audit during it measured half-faded text
            // ("Contrast failed" on text that is 14:1 at rest). The DEBUG step counter says when the fade is over;
            // the fixed margin is only the fallback when the marker never appears.
            let settled = app.descendants(matching: .any)["onb.nav.step.settled"]
            if !settled.waitForExistence(timeout: 5) { Thread.sleep(forTimeInterval: 0.6) }
            // The step at rest, for the visual record (design review of the onboarding legibility treatment).
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "onboarding-step\(step)-settled"
            shot.lifetime = .keepAlways
            add(shot)
            try audit(app, "S-0\(step)")
            app.typeKey(.return, modifierFlags: [])
        }
    }
}
