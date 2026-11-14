// M8.T13 step 6 (NFR-U9, `make perf METRIC=U9`): asks a running DEBUG AntiChat (`-QuickPanelHotkeyHook YES`) to open
// its quick panel N times, through the same handler as the global hotkey, with the panel hidden between opens (Esc).
// Each request carries this process's `systemUptime` taken just before posting, so the app's `quickPanelOpen`
// duration includes the cross-process delivery. It posts a distributed notification, never a CGEvent: tests and
// perf drivers post no global input (BackgroundRun, `make audit` no-focus-steal), and a synthetic ⌥Space would need
// an Accessibility grant for the poster (A-M8-T13a).
//   hotkey-post --count 30 --interval 1.2 [--hide-after 0.6]
import Foundation

var count = 30, interval = 1.2, hideAfter = 0.6
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--count": count = Int(it.next() ?? "") ?? count
    case "--interval": interval = Double(it.next() ?? "") ?? interval
    case "--hide-after": hideAfter = Double(it.next() ?? "") ?? hideAfter
    case "--key", "--mods": _ = it.next()  // accepted for the M8.md command line (⌥Space is the app's default)
    default: FileHandle.standardError.write(Data("hotkey-post: unknown argument \(a)\n".utf8)); exit(64)
    }
}
let name = Notification.Name("app.antichat.test.quickPanelHotkey")
let center = DistributedNotificationCenter.default()
for i in 0..<count {
    let up = ProcessInfo.processInfo.systemUptime
    center.postNotificationName(name, object: nil, userInfo: ["action": "show", "uptime": String(up), "n": String(i)],
                                deliverImmediately: true)
    Thread.sleep(forTimeInterval: hideAfter)
    center.postNotificationName(name, object: nil, userInfo: ["action": "hide"], deliverImmediately: true)
    Thread.sleep(forTimeInterval: max(0.1, interval - hideAfter))
}
print("hotkey-post: posted \(count)")
