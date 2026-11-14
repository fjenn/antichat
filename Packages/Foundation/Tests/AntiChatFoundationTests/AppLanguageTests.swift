// M9.T04 step 3 (R-102 AC1): Follow macOS by default; an override writes the app-domain AppleLanguages.
import Foundation
import Testing
@testable import AntiChatFoundation

@Suite struct AppLanguageTests {
    @Test func overrideRoundTrip() throws {
        let d = UserDefaults.inMemory()
        #expect(AppLanguage.current(d) == .system)
        AppLanguage.set(.de, d)
        #expect(d.stringArray(forKey: "AppleLanguages") == ["de"])
        #expect(AppLanguage.current(d) == .de)
        AppLanguage.set(.system, d)
        #expect(AppLanguage.current(d) == .system)
        #expect(d.object(forKey: "AppleLanguages") == nil || d.bool(forKey: "appLanguageOverride") == false)
    }

    @Test func shippedLanguagesHaveNativeNames() {
        #expect(AppLanguage.shipped.map(\.rawValue) == ["en", "de", "fr", "es", "nl", "pt"])
        #expect(AppLanguage.system.copyKey == "set.general.language.value")
        #expect(AppLanguage.pt.copyKey == "set.general.language.pt")
    }
}
