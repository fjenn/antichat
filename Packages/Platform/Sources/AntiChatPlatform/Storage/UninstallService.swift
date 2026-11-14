// M8.T11 step 2 (R-226 AC1/AC5, NFR-D7; P-platform-07 Hob `removeAfterExit` design, FrigadeHQ/hob@d02efe9
// app/src/main/uninstall.ts, MIT, design port): Uninstall AntiChat completely. Runs Remove everything's app steps
// (cancel jobs, stop the helper, relay forget, Keychain, login item, hotkeys, notifications) in-process, then writes a
// waiter script that deletes every DataPaths entry once this process has exited (the app is still using its
// container while it quits), moves AntiChat.app to the Trash and quits. The script embeds the absolute paths at
// generation time, quoted; the only globs are `AntiChat*.ips` in DiagnosticReports and `AntiChat-incognito-*` in the
// temp dir (the documented list, never a pattern outside it).
import Foundation

public struct UninstallService: Sendable {
    public let paths: DataPaths
    public let hooks: RemovalHooks
    public var keychainPrefix = DataPaths.keychainPrefix
    /// The preferences domain the waiter deletes (nil = `paths.bundleID`).
    public var defaultsDomain: String?
    /// The waiter's directory (default the temp dir).
    public var scriptDirectory: URL

    public init(paths: DataPaths, hooks: RemovalHooks = RemovalHooks()) {
        self.paths = paths
        self.hooks = hooks
        scriptDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    /// Single-quoted for /bin/sh (a `'` inside becomes `'\''`).
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// The `rm -rf` lines: plain entries quoted whole; a pattern entry = quoted directory + unquoted glob.
    public func removalLines() -> [String] {
        var lines: [String] = []
        if !paths.modelsAreInsideContainer { lines.append("rm -rf \(Self.quote(paths.models.path))") }
        for e in paths.entries where e.kind != .models {
            if let p = e.pattern {
                precondition(p.range(of: #"^[A-Za-z0-9._-]+\*[A-Za-z0-9._-]*$"#, options: .regularExpression) != nil, "unsafe glob \(p)")
                lines.append("rm -rf \(Self.quote(e.url.path))/\(p)")
            } else {
                lines.append("rm -rf \(Self.quote(e.url.path))")
            }
        }
        return lines
    }

    /// The waiter: wait for `pid` to exit, forget the preferences, delete, delete itself.
    public func script(pid: Int32) -> String {
        var s = "#!/bin/sh\n# AntiChat uninstall waiter (M8.T11): runs after the app exits.\n"
        s += "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done\n"
        // The domain first: `defaults delete` of a populated domain leaves an empty `<domain>.plist` (cfprefsd),
        // which the plist line below then removes (M8.T16 Tart run).
        s += "defaults delete \(Self.quote(defaultsDomain ?? paths.bundleID)) >/dev/null 2>&1\n"
        s += removalLines().joined(separator: "\n") + "\n"
        s += "rm -f \"$0\"\n"
        return s
    }

    /// Writes `antichat-uninstall-<uuid>.sh` (0700) and returns its URL.
    public func writeScript(pid: Int32 = getpid()) throws -> URL {
        let url = scriptDirectory.appendingPathComponent("antichat-uninstall-\(UUID().uuidString).sh")
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try Data(script(pid: pid).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Starts the waiter detached (`/usr/bin/nohup /bin/sh <script>`, no stdio), so it outlives this process.
    public static func launchDetached(_ script: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/sh", script.path]
        p.standardInput = nil
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// Steps 2.1–2.3: the in-process removals, then the waiter. The caller recycles the bundle and terminates.
    public func run(pid: Int32 = getpid(), launch: (URL) throws -> Void = UninstallService.launchDetached) async throws -> URL {
        await hooks.cancelJobs()
        await hooks.stopEngine()
        _ = await hooks.relayForget()
        KeychainInventory.deleteAll(prefix: keychainPrefix)
        await hooks.systemSteps()
        let script = try writeScript(pid: pid)
        try launch(script)
        return script
    }
}
