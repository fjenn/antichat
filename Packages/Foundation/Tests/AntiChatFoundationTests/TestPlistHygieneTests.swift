// fix/test-plist-hygiene: no test leaves a preferences plist behind. `UserDefaults(suiteName: "<prefix>-\(UUID())")`
// in a test was a file in ~/Library/Preferences the first time the test wrote to it, and nothing removed it: ≈20,000
// of them (caps-, inj-, antichat-net-test-, mcp-turn-, …) by M7. Unit and integration tests use
// `UserDefaults.inMemory()` (or `AppDefaults.standard` / the Settings scope); a UI test's `-DefaultsSuite` is on disk
// by necessity (the app is another process) and so has a stable name the app empties (`-FreshDefaultsSuite YES`);
// a probe script that names a suite per run removes its plist (`defaults delete` alone leaves the file).
import Foundation
import Testing
@testable import AntiChatFoundation

@Suite struct TestPlistHygieneTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every test target's sources (SwiftPM test targets, the Xcode integration and UI tests).
    static func testSourceRoots() throws -> [URL] {
        let fm = FileManager.default
        let packages = repo.appendingPathComponent("Packages")
        var roots = try fm.contentsOfDirectory(atPath: packages.path).sorted().map { packages.appendingPathComponent("\($0)/Tests") }
        roots += ["App/IntegrationTests", "App/UITests", "tools/catalog-tool/Tests"].map { repo.appendingPathComponent($0) }
        // The vendored osaurus copy is `Vendor/osaurus@<short>`; the short changes on every bump (M9.T09).
        let vendor = repo.appendingPathComponent("Vendor")
        let osaurus = try fm.contentsOfDirectory(atPath: vendor.path).filter { $0.hasPrefix("osaurus@") }
        #expect(osaurus.count == 1, "expected exactly one Vendor/osaurus@<short> copy, found \(osaurus)")
        roots += osaurus.map { vendor.appendingPathComponent("\($0)/Packages/OsaurusCore/Tests") }
        return roots.filter { fm.fileExists(atPath: $0.path) }
    }

    static func swiftFiles(under root: URL) -> [(rel: String, text: String)] {
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        return walk.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted().compactMap { rel in
            (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)).map { (rel, $0) }
        }
    }

    /// No test creates an on-disk UserDefaults suite. Each exception says why it writes no new plist.
    @Test func noTestCreatesAnOnDiskSuite() throws {
        let allowed: [(file: String, text: String, why: String)] = [
            ("App/UITests/FileToolsSettingsTests.swift", "UserDefaults(suiteName: suite)?.bool(",
             "reads (never writes) the UI test's stable com.antichat.uitest.filetools suite, which the app owns"),
        ]
        let rules: [(name: String, hit: (String) -> Bool)] = [
            ("an on-disk suite (use UserDefaults.inMemory())", {
                $0.range(of: #"\b(NS)?UserDefaults(\.init)?\(suiteName:"#, options: .regularExpression) != nil
            }),
            ("a persistent domain write", { $0.contains("setPersistentDomain(") }),
            ("a CFPreferences write", { $0.range(of: #"CFPreferences(Set|App)\w*\("#, options: .regularExpression) != nil }),
            ("a suite named per run (UUID / pid): one plist per run", {
                $0.range(of: "suite", options: .caseInsensitive) != nil
                    && ($0.contains("UUID()") || $0.contains("processIdentifier"))
            }),
        ]
        var found: [String] = [], used = Set<String>()
        for root in try Self.testSourceRoots() {
            let prefix = String(root.path.dropFirst(Self.repo.path.count + 1))
            for (rel, text) in Self.swiftFiles(under: root) {
                let file = "\(prefix)/\(rel)"
                guard !file.hasSuffix("TestPlistHygieneTests.swift") else { continue }  // this file names the rules
                for (i, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                    for rule in rules where rule.hit(code) {
                        if let ok = allowed.first(where: { file == $0.file && code.contains($0.text) }) {
                            used.insert(ok.file)
                        } else {
                            found.append("\(file):\(i + 1) \(rule.name)")
                        }
                    }
                }
            }
        }
        #expect(found.isEmpty, "a test left a plist in ~/Library/Preferences per run: \(found)")
        #expect(used == Set(allowed.map(\.file)), "a stale allow-list entry (the rules no longer see it): \(allowed.map(\.file))")
    }

    /// A UI test's `-DefaultsSuite` is a stable `com.antichat.uitest.<name>`, which `AntiChatUIApp` has the app empty.
    @Test func uiTestSuitesAreStableAndEmptiedByTheApp() throws {
        let ui = Self.repo.appendingPathComponent("App/UITests")
        var bad: [String] = []
        for (rel, text) in Self.swiftFiles(under: ui) {
            let literal = try NSRegularExpression(pattern: #""-DefaultsSuite",\s*"([^"]*)""#)
            for m in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let name = (text as NSString).substring(with: m.range(at: 1))
                if !name.hasPrefix("com.antichat.uitest.") || name.contains("\\(") { bad.append("\(rel): \(name)") }
            }
        }
        #expect(bad.isEmpty, "name UI-test suites com.antichat.uitest.<name>: \(bad)")
        let support = try String(contentsOf: ui.appendingPathComponent("UITestSupport.swift"), encoding: .utf8)
        #expect(support.contains(#""-FreshDefaultsSuite", "YES""#))
    }

    /// A probe script that names its suite per run (`$$`, a timestamp, a mktemp box) removes the plist as well:
    /// `defaults delete` empties the domain but leaves the file (≈100 at080/at248/vqm6/vqm7/defcap/at10x files).
    @Test func probeScriptsRemoveTheirSuitePlist() throws {
        let tools = Self.repo.appendingPathComponent("tools")
        let walk = FileManager.default.enumerator(atPath: tools.path)
        var bad: [String] = []
        let flag = try NSRegularExpression(pattern: #"-DefaultsSuite\s+"?([^\s"]+)"#)
        while let rel = walk?.nextObject() as? String {
            guard rel.hasSuffix(".sh"), !rel.contains(".venv/"), !rel.contains("node_modules/") else { continue }
            guard let text = try? String(contentsOf: tools.appendingPathComponent(rel), encoding: .utf8) else { continue }
            let perRun = flag.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .contains { (text as NSString).substring(with: $0.range(at: 1)).contains("$") }
            if perRun, !text.contains("$HOME/Library/Preferences/") { bad.append(rel) }
        }
        #expect(bad.isEmpty, "rm -f \"$HOME/Library/Preferences/$suite.plist\" after `defaults delete`: \(bad)")
    }

    /// At run time: `UserDefaults.inMemory()` is a store of its own, shared only through its `DefaultsMemory`, and
    /// leaves no file.
    @Test func inMemoryStoresLeaveNoPlist() {
        let key = "testPlistHygiene-\(UUID().uuidString)"
        let a = UserDefaults.inMemory(), b = UserDefaults.inMemory()
        a.set("a", forKey: key)
        #expect(a.string(forKey: key) == "a" && b.object(forKey: key) == nil)
        #expect(AppDefaults.standard.object(forKey: key) == nil && UserDefaults.standard.object(forKey: key) == nil)
        let shared = DefaultsMemory(systemFallback: true)
        UserDefaults.inMemory(shared).set(true, forKey: key)
        #expect(UserDefaults.inMemory(shared).bool(forKey: key), "one memory, two objects (a relaunch)")
        a.removeObject(forKey: key)
        #expect(a.object(forKey: key) == nil)
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        #expect(!FileManager.default.fileExists(atPath: prefs.appendingPathComponent("\(MemoryDefaults.missSuite).plist").path))
        #expect(AppDefaults.launchSuite == nil, "a unit-test process has no -DefaultsSuite")
    }
}
