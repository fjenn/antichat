// Every test in this module runs with its own Settings store (`.isolatedSettings`, AntiChatUI's
// `SettingsIsolation`). The module's suites run in parallel in one process and the `Defaults.Keys` all name one
// suite, so before this one test's `SettingsKeys.resetAll()` or `Defaults[.plainTextComposer] = true` changed what a
// test in another suite read (ComposerInteractionTests leg5, 2026-11-08). The trait binds a fresh in-memory store per
// test case; nothing is written to the real settings domain, and no test can reset another's state.
// `everySuiteIsIsolated` keeps it that way: a new suite (or a free @Test) without the trait fails the run.
@testable import AntiChatUI
import Defaults
import Foundation
import Testing

struct IsolatedSettingsTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    /// One store per test case (a suite's own scope would be shared by its tests).
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { test.isSuite ? nil : self }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await SettingsIsolation.withIsolatedSettings { try await function() }
    }
}

extension Trait where Self == IsolatedSettingsTrait {
    /// A fresh Settings store for each test (see SettingsIsolationTests.swift).
    static var isolatedSettings: Self { IsolatedSettingsTrait() }
}

@Suite(.isolatedSettings) struct SettingsIsolationTests {
    @Test func aScopeStartsAtTheDefaultsAndKeepsItsWrites() async {
        #expect(SettingsIsolation.isActive)
        #expect(Defaults[.plainTextComposer] == false)
        Defaults[.plainTextComposer] = true
        Defaults[.textSize] = 18
        #expect(Defaults[.plainTextComposer] == true && Defaults[.textSize] == 18)
        #expect(UserDefaults.antichat.bool(forKey: Defaults.Keys.plainTextComposer.name))
        #expect(UserDefaults.antichatIsIsolated)
        // A nested scope (another test) sees none of it, and its reset does not reach this one.
        await SettingsIsolation.withIsolatedSettings {
            #expect(Defaults[.plainTextComposer] == false && Defaults[.textSize] == Defaults.Keys.textSize.defaultValue)
            Defaults[.plainTextComposer] = true
            SettingsKeys.resetAll()
        }
        #expect(Defaults[.plainTextComposer] == true && Defaults[.textSize] == 18)
        SettingsKeys.resetAll()
        #expect(Defaults[.plainTextComposer] == false)
    }

    /// A key no other test touches, so a write elsewhere in the shared domain cannot change the answer.
    @Test func scopedWritesNeverReachTheSuite() async {
        let key = "settingsIsolationProbe-\(UUID().uuidString)"
        UserDefaults.antichat.set(true, forKey: key)
        #expect(UserDefaults.antichat.bool(forKey: key))
        let leaked = await Task.detached { UserDefaults.antichat.object(forKey: key) != nil }.value  // no scope there
        #expect(!leaked, "a scoped write leaked into the shared settings domain")
    }

    /// Observers are on the one shared suite, so they also hear other tests' scoped writes (and resets) of the same
    /// key, delivered synchronously in the writer's scope. Only notifications from this test's scope count.
    @Test func scopedWritesNotifyObservers() async {
        let mine = ScopedSettingsDefaults.scope
        let seen = Seen()
        let token = Defaults.observe(.plainTextComposer, options: []) { change in
            guard let mine, ScopedSettingsDefaults.scope === mine else { return }
            seen.append(change.newValue)
        }
        Defaults[.plainTextComposer] = true
        token.invalidate()
        let values = seen.values
        #expect(!values.isEmpty && values.allSatisfy { $0 }, "observers see the scoped value: \(values)")  // may be delivered twice
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Bool] = []
        func append(_ v: Bool) { lock.withLock { list.append(v) } }
        var values: [Bool] { lock.withLock { list } }
    }

    /// Every suite and every free-standing @Test of this module carries `.isolatedSettings` (nested suites inherit
    /// it from their parent, so declaring it again there is harmless and keeps this check a plain text scan).
    @Test func everySuiteIsIsolated() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var missing: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            let hasSuite = lines.contains { $0.contains("@Suite") }
            for (i, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if trimmed.contains("@Suite"), !trimmed.contains("contains(\"@Suite\")") {
                    // The attribute up to its declaration (it can span lines).
                    func declares(_ l: String) -> Bool {
                        let t = " " + l.trimmingCharacters(in: .whitespaces)
                        return [" struct ", " enum ", " class ", " extension "].contains { t.contains($0) }
                    }
                    let decl = lines[i...].prefix { !declares($0) }
                    let text = (Array(decl) + [lines[min(i + decl.count, lines.count - 1)]]).joined(separator: "\n")
                    if !text.contains(".isolatedSettings") { missing.append("\(name):\(i + 1)") }
                }
                if !hasSuite, trimmed.hasPrefix("@Test"), !line.contains(".isolatedSettings") { missing.append("\(name):\(i + 1)") }
            }
        }
        #expect(missing.isEmpty, "add .isolatedSettings to: \(missing)")
    }
}
