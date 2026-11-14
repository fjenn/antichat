// M8.T11 (AT-226 AC1/AC5): the uninstall plan and the detached waiter over a seeded scratch tree.
//   make test-unit FILTER=UninstallServiceTests
import AntiChatFoundation
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite("UninstallServiceTests", .serialized) struct UninstallServiceTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized

    @Test func planHasEveryPathQuotedAndNothingOutside() throws {
        let t = try StorageFixture.make("uninstall-plan-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: t.root) }
        var paths = t.paths
        // A moved Models folder with a quote and a space in its name (quoting).
        paths.models = t.root.appendingPathComponent("Drive O'Neil/Models", isDirectory: true)
        let svc = UninstallService(paths: paths)
        let lines = svc.removalLines()
        #expect(lines.first == "rm -rf " + UninstallService.quote(paths.models.path))
        #expect(lines.first?.contains(#"'\''"#) == true)
        for e in paths.entries where e.kind != .models {
            #expect(lines.contains { $0.contains(UninstallService.quote(e.url.path)) }, "\(e.kind)")
        }
        // Only the documented globs, each after a quoted directory; every path under the scratch root.
        let globs = lines.filter { $0.contains("*") }
        #expect(globs.count == 5)  // HTTPStorages, bundle-id caches (M10), FileTools containers, DiagnosticReports, incognito temp
        #expect(globs.allSatisfy { $0.range(of: #"^rm -rf '[^']+'/[A-Za-z0-9._-]+\*[A-Za-z0-9._-]*$"#, options: .regularExpression) != nil })
        #expect(lines.allSatisfy { $0.contains(t.root.path) || $0.contains("Drive O") })
        let script = svc.script(pid: 4242)
        #expect(script.hasPrefix("#!/bin/sh\n") && script.contains("while kill -0 4242") && script.hasSuffix("rm -f \"$0\"\n"))
        // `defaults delete` of a populated domain leaves an empty plist behind (cfprefsd): the domain goes first, the
        // plist file after it (M8.T16 Tart run).
        let plist = paths.entries.first { $0.kind == .preferences }!.url.path
        if let d = script.range(of: "defaults delete "), let f = script.range(of: "rm -rf \(UninstallService.quote(plist))") {
            #expect(d.lowerBound < f.lowerBound, "defaults delete before the plist is removed")
        } else {
            Issue.record("the waiter forgets the domain and removes the plist")
        }
        // shellcheck over the generated script (a temp copy; nothing tracked changes per run).
        let sample = t.root.appendingPathComponent("sample-uninstall.sh")
        try script.write(to: sample, atomically: true, encoding: .utf8)
        for sc in ["/opt/homebrew/bin/shellcheck", Self.repo.appendingPathComponent(".tools/bin/shellcheck").path]
        where FileManager.default.isExecutableFile(atPath: sc) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sc)
            p.arguments = ["-s", "sh", "-e", "SC2035", sample.path]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
            break
        }
    }

    @Test func waiterDeletesAfterTheProcessExits() async throws {
        let t = try StorageFixture.make("uninstall-run-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: t.root) }
        // A stand-in "app" process the waiter waits for.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["1"]
        try sleeper.run()
        var svc = UninstallService(paths: t.paths)
        svc.keychainPrefix = "app.antichat.test-none-\(UUID().uuidString)."
        svc.defaultsDomain = "app.antichat.test-uninstall-\(UUID().uuidString)"
        svc.scriptDirectory = t.root.appendingPathComponent("scripts")
        let order = OrderLog()
        let script = try await svc.run(pid: sleeper.processIdentifier) { url in
            order.add("launch")
            try UninstallService.launchDetached(url)
        }
        #expect(order.items == ["launch"])
        #expect(FileManager.default.fileExists(atPath: t.paths.container.path), "nothing deleted while the app runs")
        let perms = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        for _ in 0..<100 where !t.paths.existing().isEmpty || FileManager.default.fileExists(atPath: script.path) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(t.paths.existing().isEmpty, "zero files after exit: \(t.paths.existing().map(\.path))")
        #expect(!FileManager.default.fileExists(atPath: script.path), "the waiter removes itself")
        #expect(FileManager.default.fileExists(atPath: t.paths.home.appendingPathComponent("Library/Logs/DiagnosticReports/Other-2026.ips").path))
    }
}
