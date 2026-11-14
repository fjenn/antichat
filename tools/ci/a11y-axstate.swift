// a11y-axstate <seconds> (Q-015 r6, M9.T03): answers the accessibility audit tests' questions about the running app's
// accessibility tree, which the sandboxed UI test runner cannot read (no Accessibility grant). Started outside the
// runner by tools/ci/with-mcp-ref.sh, like webauth-continue. Handshake through the runner's own temporary directory:
// the test writes `a11y-axstate-<id>.req` (one line: a window identifier prefix); this helper writes
// `a11y-axstate-<id>.resp` (JSON) for the newest AntiChat dev process:
//   switches       AXCheckBox elements with subrole AXToggle (SwiftUI's labels-hidden switch) in those windows
//   focusedField   the app's AXFocusedUIElement is a text field or combo box
//   clearOrphans   search fields whose AXClearButton is not in their AXChildren (KeyboardShortcuts' recorder);
//                  quickPanelClear: the one on the quick-panel hotkey recorder
//   progressIndicators  AXProgressIndicator and AXBusyIndicator elements in those windows
//   outOfTree      every element reached through an element-valued attribute but not through AXChildren (diagnosis)
// Read-only: it never performs an action. Needs the Accessibility grant of the process that runs the UI tests.
//   swiftc -O -o build/a11y-axstate tools/ci/a11y-axstate.swift
import AppKit
import ApplicationServices

func ax(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] { (ax(e, "AXChildren") as? [AXUIElement]) ?? [] }
func names(_ e: AXUIElement) -> [String] { var n: CFArray?; AXUIElementCopyAttributeNames(e, &n); return (n as? [String]) ?? [] }
func describe(_ e: AXUIElement) -> String {
    "\(ax(e, "AXRole") as? String ?? "?")/\(ax(e, "AXSubrole") as? String ?? "") id=\(ax(e, "AXIdentifier") as? String ?? "")"
        + " desc=\(ax(e, "AXDescription") as? String ?? "")"
}

func answer(prefix: String, pidFile: String) -> [String: Any] {
    // Several instances can run at once (a gate's integration tests launch the same bundle): take the one the UI test
    // drives, i.e. the instance that has a window with this identifier prefix, the active one first.
    let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "app.antichat.AntiChat.dev" }
        .sorted { ($0.isActive ? 1 : 0, $0.launchDate ?? .distantPast) > ($1.isActive ? 1 : 0, $1.launchDate ?? .distantPast) }
    func hasWindow(_ r: NSRunningApplication) -> Bool {
        let a = AXUIElementCreateApplication(r.processIdentifier)
        AXUIElementSetMessagingTimeout(a, 1)
        return ((ax(a, "AXWindows") as? [AXUIElement]) ?? []).contains { ((ax($0, "AXIdentifier") as? String) ?? "").hasPrefix(prefix) }
    }
    // Exact: the pid the launched app wrote to the test's pid file (DEBUG, ANTICHAT_A11Y_PIDFILE).
    if let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
       let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
       let r = NSRunningApplication(processIdentifier: pid) {
        return answer(app: r, prefix: prefix)
    }
    guard let target = running.first(where: hasWindow) else {
        return ["error": "no running app.antichat.AntiChat.dev with a window \(prefix)*"]
    }
    return answer(app: target, prefix: prefix)
}

func answer(app target: NSRunningApplication, prefix: String) -> [String: Any] {
    let app = AXUIElementCreateApplication(target.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 2)
    var tree: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) { tree.append(e); if d < 90 { for k in kids(e) { walk(k, d + 1) } } }
    for w in (ax(app, "AXWindows") as? [AXUIElement]) ?? [] where ((ax(w, "AXIdentifier") as? String) ?? "").hasPrefix(prefix) {
        walk(w, 0)
    }
    func inTree(_ x: AXUIElement) -> Bool { tree.contains { CFEqual($0, x) } }
    var switches = 0, clearOrphans = 0, progressIndicators = 0, quickPanelClear = 0
    var roles: [String: Int] = [:]
    var outOfTree: [String] = []
    for e in tree {
        let role = ax(e, "AXRole") as? String ?? ""
        let sub = ax(e, "AXSubrole") as? String ?? ""
        roles[sub.isEmpty ? role : "\(role)/\(sub)", default: 0] += 1
        if role == "AXCheckBox", sub == "AXToggle" { switches += 1 }
        if role == "AXProgressIndicator" || role == "AXBusyIndicator" { progressIndicators += 1 }
        if sub == "AXSearchField", let c = ax(e, "AXClearButton") {
            let clear = c as! AXUIElement
            if !kids(e).contains(where: { CFEqual($0, clear) }) {
                clearOrphans += 1
                if (ax(e, "AXIdentifier") as? String) == "settings.control.quickPanelHotkey" { quickPanelClear += 1 }
            }
        }
        for a in names(e) where !["AXParent", "AXWindow", "AXTopLevelUIElement", "AXChildren", "AXChildrenInNavigationOrder"].contains(a) {
            guard let v = ax(e, a) else { continue }
            var els: [AXUIElement] = []
            if CFGetTypeID(v) == AXUIElementGetTypeID() { els = [v as! AXUIElement] }
            else if let arr = v as? [AnyObject] { els = arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil } }
            for x in els where !inTree(x) { outOfTree.append("\(a) of \(describe(e)) -> \(describe(x))") }
        }
    }
    var focusedField = false
    var focused = "none"
    if let f = ax(app, "AXFocusedUIElement") {
        let fe = f as! AXUIElement
        let role = ax(fe, "AXRole") as? String ?? ""
        focused = describe(fe) + (inTree(fe) ? "" : " (not in the window tree)")
        focusedField = role == "AXTextField" || role == "AXComboBox"
    }
    return ["switches": switches, "focusedField": focusedField, "focused": focused, "clearOrphans": clearOrphans, "progressIndicators": progressIndicators, "quickPanelClear": quickPanelClear,
            "outOfTree": outOfTree, "elements": tree.count, "pid": Int(target.processIdentifier),
            "roles": roles.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")]
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "7200") ?? 7200
guard AXIsProcessTrusted() else { FileHandle.standardError.write(Data("a11y-axstate: no Accessibility grant\n".utf8)); exit(2) }
let dir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Containers/app.antichat.AntiChatUITests.xctrunner/Data/tmp", isDirectory: true)
let end = Date().addingTimeInterval(seconds)
let fm = FileManager.default
while Date() < end {
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("a11y-axstate-") && name.hasSuffix(".req") {
        let req = dir.appendingPathComponent(name)
        let lines = ((try? String(contentsOf: req, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        let prefix = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let pidFile = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : ""
        let resp = dir.appendingPathComponent(String(name.dropLast(4)) + ".resp")
        if let data = try? JSONSerialization.data(withJSONObject: answer(prefix: prefix, pidFile: pidFile)) {
            try? data.write(to: resp, options: .atomic)
        }
        try? fm.removeItem(at: req)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
