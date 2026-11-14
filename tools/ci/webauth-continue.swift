// webauth-continue <seconds> [log] (Q-015 r5/r6, AT-257 UI leg): plays the user's one action in the sign-in leg. macOS
// shows ASWebAuthenticationSession's "“AntiChat” wants to use “127.0.0.1” to Sign In" alert from the authentication
// agent, a separate process the sandboxed UI test runner cannot reach (r4: no bundle id, no process-id initialiser).
// This watcher, started outside the runner by tools/ci/with-mcp-ref.sh, presses that alert's Continue through the
// Accessibility API, and exits after `seconds`.
//
// r6: r5's watcher printed nothing in any run (it found no window). It now looks wider and says what it sees:
//   - processes: every running application (agents included) plus every owner of an on-screen window
//     (CGWindowList; the authentication agent can be a bare executable with no NSRunningApplication entry);
//   - windows: AXWindows, the application element's own window/sheet children, and each window's sheets;
//   - match: a dialog-like window (AXDialog / AXSystemDialog / AXSheet, or any window of a non-AntiChat process) whose
//     text says "wants to use" or "Sign In", and names AntiChat or the loopback host. AntiChat's own windows are
//     never pressed unless the text says "wants to use" (the add-connection sheet has its own Continue);
//   - button: the AXButton titled "Continue" (any case), else the window's AXDefaultButton.
// Every dialog-like window seen is logged once (pid, process, role/subrole, the first 160 characters of its text), to
// stderr and to the log file (default build/webauth-continue.log), plus a heartbeat every 30 s.
// Needs the Accessibility grant of the process that runs the UI tests.
//   swiftc -O -o build/webauth-continue tools/ci/webauth-continue.swift
import AppKit
import ApplicationServices
import CoreGraphics

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "600") ?? 600
let logPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "build/webauth-continue.log"
FileManager.default.createFile(atPath: logPath, contents: nil)
let logHandle = FileHandle(forWritingAtPath: logPath)

func log(_ s: String) {
    let line = "webauth-continue \(ISO8601DateFormatter().string(from: Date())): \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
    logHandle?.seekToEndOfFile()
    logHandle?.write(Data(line.utf8))
}

func ax(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}

func children(_ e: AXUIElement) -> [AXUIElement] { (ax(e, "AXChildren") as? [AXUIElement]) ?? [] }

func texts(_ e: AXUIElement, _ depth: Int = 0) -> [String] {
    guard depth < 12 else { return [] }
    var out: [String] = []
    for k in ["AXValue", "AXTitle", "AXDescription", "AXLabel"] {
        if let s = ax(e, k) as? String, !s.isEmpty { out.append(s) }
    }
    for c in children(e) { out += texts(c, depth + 1) }
    return out
}

func continueButton(_ e: AXUIElement, _ depth: Int = 0) -> AXUIElement? {
    guard depth < 12 else { return nil }
    if (ax(e, "AXRole") as? String) == "AXButton",
       let t = (ax(e, "AXTitle") as? String) ?? (ax(e, "AXDescription") as? String),
       t.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Continue") == .orderedSame { return e }
    for c in children(e) { if let b = continueButton(c, depth + 1) { return b } }
    return nil
}

/// Windows and sheets of an application element.
func windows(of app: AXUIElement) -> [AXUIElement] {
    var out = (ax(app, "AXWindows") as? [AXUIElement]) ?? []
    for c in children(app) where ["AXWindow", "AXSheet"].contains(ax(c, "AXRole") as? String ?? "") {
        if !out.contains(where: { CFEqual($0, c) }) { out.append(c) }
    }
    var sheets: [AXUIElement] = []
    for w in out {
        sheets += (ax(w, "AXSheets") as? [AXUIElement]) ?? []
        sheets += children(w).filter { (ax($0, "AXRole") as? String) == "AXSheet" }
    }
    return out + sheets
}

/// Every pid worth looking at: running applications plus owners of on-screen windows (any layer).
func candidatePIDs() -> [pid_t: String] {
    var out: [pid_t: String] = [:]
    for a in NSWorkspace.shared.runningApplications { out[a.processIdentifier] = a.localizedName ?? a.bundleIdentifier ?? "?" }
    let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in info {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t else { continue }
        if out[pid] == nil { out[pid] = (w[kCGWindowOwnerName as String] as? String) ?? "pid \(pid)" }
    }
    return out
}

log("start (\(Int(seconds)) s), Accessibility trusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else { log("no Accessibility grant; exiting"); exit(2) }
let me = getpid()
let end = Date().addingTimeInterval(seconds)
var seen = Set<String>()
var pressed = 0
var lastBeat = Date()
while Date() < end {
    for (pid, name) in candidatePIDs() where pid != me {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.5)
        let isAntiChat = name.contains("AntiChat")
        // Plain windows are read only for agents / bare executables (the authentication agent), never for every
        // regular app's every window (a deep AX walk of Xcode or a browser twice a second).
        let agent = NSRunningApplication(processIdentifier: pid).map { $0.activationPolicy != .regular } ?? true
        for w in windows(of: el) {
            let role = ax(w, "AXRole") as? String ?? ""
            let subrole = ax(w, "AXSubrole") as? String ?? ""
            let dialogLike = role == "AXSheet" || ["AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(subrole)
            guard dialogLike || (agent && !isAntiChat) else { continue }
            let words = texts(w).joined(separator: " ")
            let asks = words.contains("wants to use")
            let signIn = asks || words.localizedCaseInsensitiveContains("sign in")
            let ours = words.contains("AntiChat") || words.contains("127.0.0.1") || words.localizedCaseInsensitiveContains("localhost")
            if dialogLike || signIn {
                let sig = "\(pid)|\(role)|\(subrole)|\(words.prefix(160))"
                if seen.insert(sig).inserted {
                    log("seen pid \(pid) \(name) \(role)/\(subrole): \(words.prefix(160))")
                }
            }
            guard signIn, ours, asks || !isAntiChat else { continue }
            let button = continueButton(w) ?? (ax(w, "AXDefaultButton").map { $0 as! AXUIElement })
            guard let b = button else { log("matched pid \(pid) \(name) but found no Continue / default button"); continue }
            if AXUIElementPerformAction(b, kAXPressAction as CFString) == .success {
                pressed += 1
                log("pressed Continue (\(name), pid \(pid)) #\(pressed)")
                print("webauth-continue: pressed Continue (\(name))")
                fflush(stdout)
            } else {
                log("press failed (\(name), pid \(pid))")
            }
        }
    }
    if Date().timeIntervalSince(lastBeat) >= 30 {
        lastBeat = Date()
        log("heartbeat: pressed \(pressed), dialog-like windows seen \(seen.count)")
    }
    Thread.sleep(forTimeInterval: 0.5)
}
log("done, pressed \(pressed)")
exit(0)
