// Q-015 r5 (DEBUG): accessibility attributes XCUITest does not surface — a slider's AXValueDescription (what VoiceOver
// speaks for SwiftUI's `.accessibilityValue`; XCUIElement.value is the raw AXValue) and AXHelp (the `.help` tooltip).
// The UI test runner is sandboxed, so it cannot read them with the Accessibility API (AXUIElement calls return
// nothing there). With `ANTICHAT_AX_ATTR_LOG=<file>` and `ANTICHAT_AX_ATTR_IDS=<id>,<id>…` this probe reads them
// in-process every 0.25 s from the app's own accessibility objects (the ones VoiceOver queries through the AX server)
// and appends `<id>\t<AXValueDescription>\t<AXHelp>` whenever that line changes. Reads only; compiled out of Release.
#if DEBUG
import AppKit

@MainActor public enum AXAttributeProbe {
    private static var last: [String: String] = [:]
    private static var timer: Timer?

    public static func startIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard timer == nil, let path = env["ANTICHAT_AX_ATTR_LOG"],
              let ids = env["ANTICHAT_AX_ATTR_IDS"]?.split(separator: ",").map(String.init), !ids.isEmpty else { return }
        let wanted = Set(ids)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { sample(wanted, path: path) }
        }
    }

    private static func sample(_ wanted: Set<String>, path: String) {
        var found: [String: NSObject] = [:]
        for w in NSApp.windows where w.isVisible { walk(w, wanted, &found, depth: 0) }
        for (id, el) in found {
            let line = "\(id)\t\(string(el, "accessibilityValueDescription") ?? "")\t\(string(el, "accessibilityHelp") ?? "")"
            guard last[id] != line else { continue }
            last[id] = line
            append(line, path: path)
        }
    }

    private static func string(_ o: NSObject, _ name: String) -> String? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue() as? String
    }

    private static func walk(_ o: NSObject, _ wanted: Set<String>, _ found: inout [String: NSObject], depth: Int) {
        guard depth < 80, found.count < wanted.count else { return }
        if let id = string(o, "accessibilityIdentifier"), wanted.contains(id), found[id] == nil { found[id] = o }
        let sel = NSSelectorFromString("accessibilityChildren")
        guard o.responds(to: sel), let kids = o.perform(sel)?.takeUnretainedValue() as? [NSObject] else { return }
        for k in kids { walk(k, wanted, &found, depth: depth + 1) }
    }

    private static func append(_ line: String, path: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
#endif
