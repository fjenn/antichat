// The installer's "Applications" drop target (owner, 2026-11-15: dragging AntiChat onto Applications must install it
// AND open it). A plain Finder symlink cannot run anything, so the DMG's Applications icon is this tiny app wearing
// Apple's Applications folder icon. Dropping AntiChat.app on it:
//   1. checks the dropped bundle is AntiChat signed by our team (SecStaticCode, the same requirement as the app),
//   2. quits a running AntiChat, moves an old /Applications/AntiChat.app to the Trash and copies the new one in
//      (administrator prompt only when /Applications is not writable),
//   3. clears the quarantine flag on the copy (its signature was just verified), registers it with Launch Services so
//      Spotlight / Apps lists it at once, opens it, and ejects the installer volume.
// Finder launches it WITHOUT the dropped item (an app dropped on an app; macOS 26), so launched with no document it
// installs the AntiChat.app beside it on the installer volume — the same as a drop. Outside the installer (no sibling)
// it just shows the Applications folder.
// The installer is a compressed read-write image (package-dmg.sh): Finder refuses drops onto an app on a read-only
// volume.
// Its Finder icon is Apple's ApplicationsFolderIcon set as a custom icon on the DMG copy (package-dmg.sh): a bundle
// icon (CFBundleIconFile) would be drawn inside macOS 26's grey legacy-icon frame. ANTICHAT_INSTALLER_DRYRUN=1 only logs.
import AppKit
import Security
import os

let log = Logger(subsystem: "app.antichat.Installer", category: "drop")

let bundleID = "app.antichat.AntiChat"
let teamID = "446XT9839S"
let dest = URL(fileURLWithPath: "/Applications/AntiChat.app")

final class Delegate: NSObject, NSApplicationDelegate {
    var handled = false

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard !handled else { return }
        handled = true
        log.notice("open urls: \(urls.map(\.path), privacy: .public)")
        guard let src = urls.first(where: { Bundle(url: $0)?.bundleIdentifier == bundleID }) else {
            fail("Drag AntiChat onto Applications to install it.")
            return
        }
        if ProcessInfo.processInfo.environment["ANTICHAT_INSTALLER_DRYRUN"] != nil { log.notice("dry run: would install \(src.path, privacy: .public)"); NSApp.terminate(nil); return }
        install(src)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        log.notice("launched")
        // A drop delivers `open urls` before this returns; give it a beat, then treat it as a double-click.
        // Finder launches a drop target without the dropped item when the item is an app (observed on macOS 26, both
        // for this app and for an alias to it), so the drop itself is the signal: install the AntiChat.app beside us.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !self.handled else { return }
            self.handled = true
            let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("AntiChat.app")
            if Bundle(url: sibling)?.bundleIdentifier == bundleID {
                log.notice("no document; installing sibling \(sibling.path, privacy: .public)")
                if ProcessInfo.processInfo.environment["ANTICHAT_INSTALLER_DRYRUN"] != nil { NSApp.terminate(nil); return }
                self.install(sibling)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                NSApp.terminate(nil)
            }
        }
    }

    func install(_ src: URL) {
        guard verify(src) else { fail("This copy of AntiChat is damaged. Download it again from antichat.ai."); return }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(8)
        while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        do {
            try copyIn(src)
        } catch {
            fail("AntiChat could not be copied to Applications (\(error.localizedDescription)).")
            return
        }
        removexattr(dest.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        LSRegisterURL(dest as CFURL, true)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
            DispatchQueue.main.async { self.ejectAndQuit(volumeOf: src) }
        }
    }

    func copyIn(_ src: URL) throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: "/Applications/.AntiChat-installing.app")
        if fm.isWritableFile(atPath: "/Applications") {
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.moveItem(at: tmp, to: dest)
            return
        }
        // Standard user: one administrator prompt for the copy.
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let sh = "/bin/rm -rf \(q(dest.path)) && /usr/bin/ditto \(q(src.path)) \(q(dest.path))"
        let script = "do shell script \"\(sh.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { throw NSError(domain: "AntiChatInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: err[NSAppleScript.errorMessage] as? String ?? "cancelled"]) }
    }

    func verify(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        let text = "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        #if DEBUG
        let checkReq: SecRequirement? = nil
        #else
        guard SecRequirementCreateWithString(text as CFString, [], &req) == errSecSuccess else { return false }
        let checkReq = req
        #endif
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), checkReq) == errSecSuccess
    }

    func ejectAndQuit(volumeOf src: URL) {
        let vol = src.deletingLastPathComponent()
        if vol.path.hasPrefix("/Volumes/") {
            // Detach after this process (which runs from that volume) has exited.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1.5; /usr/bin/hdiutil detach -quiet \"$0\" || /usr/bin/hdiutil detach -force -quiet \"$0\"", vol.path]
            try? p.run()
        }
        NSApp.terminate(nil)
    }

    func fail(_ message: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "AntiChat Installer"
        a.informativeText = message
        a.runModal()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
