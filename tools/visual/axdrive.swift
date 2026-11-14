// AT-VQ-M4 Release leg driver: drives a running app through the Accessibility API only (no activation, no cursor move,
// no synthetic input events of any kind — tools/ci/no-focus-steal.sh).
//   axdrive tree <pid> [maxDepth]                 dump role / identifier / title / value / frame
//   axdrive find <pid> <identifier>               print the frame of the first element with that identifier
//   axdrive set <pid> <identifier> <text>         set AXValue (text fields / text views)
//   axdrive press <pid> <identifier|title:...>    AXPress the first match
//   axdrive confirm <pid> <identifier>            AXConfirm (submit a text field)
//   axdrive resize <pid> <w> <h>                  size + place the first standard window
//   axdrive windows <pid>                         CGWindowID  bounds  title  for each on-screen window of the pid
//   axdrive wait <pid> <identifier> <seconds>     exit 0 when the element exists, 1 on timeout
//   axdrive count|waitcount <pid> <identifier> [n seconds]   number of matches / wait for at least n
// <identifier> may end in @last (the last match, e.g. the newest picture card).
import AppKit
import ApplicationServices

func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

func walk(_ e: AXUIElement, depth: Int = 0, max: Int = 60, _ visit: (AXUIElement, Int) -> Bool) -> Bool {
    if visit(e, depth) { return true }
    if depth >= max { return false }
    for c in children(e) where walk(c, depth: depth + 1, max: max, visit) { return true }
    return false
}

func matches(_ e: AXUIElement, _ key: String) -> Bool {
    if key.hasPrefix("title:") {
        let t = String(key.dropFirst(6))
        return str(e, kAXTitleAttribute) == t || str(e, kAXDescriptionAttribute) == t
    }
    if key.hasPrefix("prefix:") { return str(e, kAXIdentifierAttribute)?.hasPrefix(String(key.dropFirst(7))) ?? false }
    return str(e, kAXIdentifierAttribute) == key
}

func findAll(_ app: AXUIElement, _ key: String) -> [AXUIElement] {
    var hits: [AXUIElement] = []
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        _ = walk(w) { e, _ in if matches(e, key) { hits.append(e) }; return false }
    }
    return hits
}

/// `key` = the first match; `key@last` = the last one (the newest card of a transcript).
func find(_ app: AXUIElement, _ key: String) -> AXUIElement? {
    if key.hasSuffix("@last") { return findAll(app, String(key.dropLast(5))).last }
    var hit: AXUIElement?
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        if walk(w, { e, _ in if matches(e, key) { hit = e; return true }; return false }) { break }
    }
    return hit
}

let a = CommandLine.arguments
guard a.count >= 3, let pid = pid_t(a[2]) else {
    FileHandle.standardError.write(Data("usage: axdrive tree|find|set|press|confirm|resize|windows|wait <pid> …\n".utf8)); exit(2)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 10)

switch a[1] {
case "tree":
    let maxDepth = a.count > 3 ? Int(a[3]) ?? 60 : 60
    for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        _ = walk(w, max: maxDepth) { e, d in
            let role = str(e, kAXRoleAttribute) ?? "?"
            let id = str(e, kAXIdentifierAttribute).map { " #\($0)" } ?? ""
            let t = (str(e, kAXTitleAttribute) ?? str(e, kAXDescriptionAttribute)).map { " \"\($0.prefix(60))\"" } ?? ""
            let v = (attr(e, kAXValueAttribute) as? String).map { " =\"\($0.prefix(60))\"" } ?? ""
            let f = frame(e).map { " [\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))]" } ?? ""
            print(String(repeating: "  ", count: d) + role + id + t + v + f)
            return false
        }
    }
case "find":
    guard let e = find(app, a[3]) else { print("missing"); exit(1) }
    print(frame(e).map { "\($0.minX) \($0.minY) \($0.width) \($0.height)" } ?? "noframe")
case "count":  // count <pid> <identifier>: how many elements carry it
    print(findAll(app, a[3]).count)
case "waitcount":  // waitcount <pid> <identifier> <n> <seconds>: exit 0 once at least n exist
    let deadline = Date().addingTimeInterval(Double(a[5]) ?? 60)
    while Date() < deadline {
        if findAll(app, a[3]).count >= Int(a[4]) ?? 1 { exit(0) }
        Thread.sleep(forTimeInterval: 1)
    }
    exit(1)
case "wait":
    let deadline = Date().addingTimeInterval(Double(a[4]) ?? 60)
    while Date() < deadline {
        if find(app, a[3]) != nil { exit(0) }
        Thread.sleep(forTimeInterval: 1)
    }
    exit(1)
case "set":
    guard let e = find(app, a[3]) else { print("missing \(a[3])"); exit(1) }
    AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let r = AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, a[4] as CFString)
    print("set \(a[3]): \(r.rawValue)"); exit(r == .success ? 0 : 1)
case "press", "confirm":
    guard let e = find(app, a[3]) else { print("missing \(a[3])"); exit(1) }
    let r = AXUIElementPerformAction(e, (a[1] == "press" ? kAXPressAction : kAXConfirmAction) as CFString)
    // SwiftUI buttons that start async work often answer failure / cannotComplete although the action ran (seen:
    // the send button, -25200, message sent): only a missing element fails here; the caller checks the effect.
    print("\(a[1]) \(a[3]): \(r.rawValue)"); exit(0)
case "resize":  // resize <pid> <w> <h>: the first standard window (shots at the visual-QA size)
    guard let w = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { str($0, kAXSubroleAttribute) == kAXStandardWindowSubrole }),
          let width = Double(a[3]), let height = Double(a[4]) else { print("no window"); exit(1) }
    var size = CGSize(width: width, height: height), origin = CGPoint(x: 40, y: 40)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
    let r = AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    print("resize: \(r.rawValue) → \(frame(w).map { "\($0.width)x\($0.height)" } ?? "?")"); exit(r == .success ? 0 : 1)
case "windows":
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = info[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print("\(info[kCGWindowNumber as String] ?? 0) \(Int(b["Width"] ?? 0))x\(Int(b["Height"] ?? 0)) layer=\(info[kCGWindowLayer as String] ?? 0) \(info[kCGWindowName as String] ?? "")")
    }
default:
    print("unknown command"); exit(2)
}
