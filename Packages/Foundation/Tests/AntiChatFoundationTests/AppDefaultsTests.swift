// fix/shared-defaults-isolation: a unit-test process keeps the app's defaults to itself (AppDefaults). The test tool's
// `.standard` domain is shared by every test process on the Mac; nothing written there may show here, nothing written
// here may land there, and the store never leaves a plist in ~/Library/Preferences.
import Foundation
import Testing
@testable import AntiChatFoundation

@Suite struct AppDefaultsTests {
    @Test func aTestProcessHasItsOwnStore() {
        #expect(AppDefaults.isTestProcess() && AppDefaults.isPrivate)
        let key = "appDefaultsTests-\(UUID().uuidString)"
        UserDefaults.standard.set("shared", forKey: key)  // as another test process would
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(AppDefaults.standard.object(forKey: key) == nil, "the shared domain showed through")
        AppDefaults.standard.set("own", forKey: key)
        defer { AppDefaults.standard.removeObject(forKey: key) }
        #expect(AppDefaults.standard.string(forKey: key) == "own")
        #expect(UserDefaults.standard.string(forKey: key) == "shared", "a private write reached the shared domain")
    }

    /// Like `.standard`: registered defaults, launch arguments and NSGlobalDomain are read; typed accessors agree.
    @Test func readsLikeStandard() {
        let key = "appDefaultsTests-reg-\(UUID().uuidString)"
        AppDefaults.standard.register(defaults: [key: 7])
        #expect(AppDefaults.standard.integer(forKey: key) == 7)
        AppDefaults.standard.set(9, forKey: key)
        #expect(AppDefaults.standard.integer(forKey: key) == 9 && AppDefaults.standard.double(forKey: key) == 9)
        AppDefaults.standard.removeObject(forKey: key)
        #expect(AppDefaults.standard.integer(forKey: key) == 7)
        #expect(AppDefaults.standard.string(forKey: "AppleLocale") == UserDefaults.standard.string(forKey: "AppleLocale"))
        AppDefaults.standard.set(["chat", "voice"], forKey: key)
        #expect(AppDefaults.standard.stringArray(forKey: key) == ["chat", "voice"])
        AppDefaults.standard.removeObject(forKey: key)
    }

    @Test func neverAPlist() {
        AppDefaults.standard.set(true, forKey: "appDefaultsTests-plist")
        AppDefaults.standard.removeObject(forKey: "appDefaultsTests-plist")
        let prefs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        #expect(!FileManager.default.fileExists(atPath: prefs.appendingPathComponent("\(MemoryDefaults.missSuite).plist").path))
    }

    /// Writes notify KVO observers of the store (Defaults' and @AppStorage's observation).
    @Test func writesNotifyObservers() {
        final class Observer: NSObject, @unchecked Sendable {
            var seen: [Any?] = []
            override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                       context: UnsafeMutableRawPointer?) {
                seen.append(change?[.newKey])
            }
        }
        let key = "appDefaultsTestsKVO\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let o = Observer()
        AppDefaults.standard.addObserver(o, forKeyPath: key, options: [.new], context: nil)
        AppDefaults.standard.set(true, forKey: key)
        AppDefaults.standard.removeObserver(o, forKeyPath: key)
        AppDefaults.standard.removeObject(forKey: key)
        #expect((o.seen.last as? NSNumber)?.boolValue == true, "\(o.seen)")
    }
}
