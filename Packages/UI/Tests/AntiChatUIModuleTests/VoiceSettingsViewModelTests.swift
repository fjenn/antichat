// M3.T08 step 8 (R-053, settings-map §5): the Voice settings defaults, the values the voice paths read
// (VoicePreferences), the voice list (≥ 6, Kokoro with the pack, system voices of the language then English without),
// the speed label and the Spoken language list (Parakeet's 25 ∪ WhisperKit's, independent of the UI language).
//   make test-unit FILTER=VoiceSettingsViewModelTests
import AntiChatEngineProtocol
import Defaults
import Foundation
import Testing
@testable import AntiChatUI

// Serialized with the window suites: SettingsKeys.resetAll() here must not race tests that set Defaults (M10 gate flake).
extension WindowSuites {
@MainActor @Suite(.serialized, .isolatedSettings)
struct VoiceSettingsViewModelTests {
    @Test func defaultsFollowTheSettingsMap() {
        SettingsKeys.resetAll()
        #expect(Defaults[.voiceInputDevice] == "")
        #expect(Defaults[.voiceSpokenLanguage] == "auto")
        #expect(Defaults[.voiceID] == "")
        #expect(Defaults[.voiceRate] == 1.0)
        #expect(Defaults[.voiceMode] == "handsFree")
        #expect(VoicePreferences.spokenLanguage == nil && VoicePreferences.inputDeviceUID == nil && VoicePreferences.rate == 1)
    }

    @Test func changesAreReadAtTheNextUtterance() {
        SettingsKeys.resetAll()
        defer { SettingsKeys.resetAll() }
        Defaults[.voiceSpokenLanguage] = "ja"
        Defaults[.voiceInputDevice] = "uid-usb"
        Defaults[.voiceRate] = 1.25
        Defaults[.voiceID] = "bf_emma"
        #expect(VoicePreferences.spokenLanguage == "ja")
        #expect(VoicePreferences.inputDeviceUID == "uid-usb")
        #expect(VoicePreferences.rate == 1.25 && VoicePreferences.voiceID == "bf_emma")
        Defaults[.voiceRate] = 3
        #expect(VoicePreferences.rate == 1.5, "clamped to 0.75…1.5")
    }

    @Test func kokoroVoicesWithThePack() {
        let v = VoiceChoice.available(packReady: true, spokenLanguage: "auto", system: { [] })
        #expect(v.count >= 6)
        #expect(v.first?.id == KokoroVoices.defaultID)
        #expect(VoiceChoice.selected("", in: v) == "af_heart", "first of ≥ 6 voices")
        #expect(VoiceChoice.selected("bm_george", in: v) == "bm_george")
    }

    @Test func systemVoicesOwnLanguageFirstThenEnglish() {
        let sys: [(id: String, name: String, language: String)] = [
            ("en1", "Samantha", "en-US"), ("de1", "Anna", "de-DE"), ("en2", "Daniel", "en-GB"), ("fr1", "Thomas", "fr-FR"),
            ("en3", "Karen", "en-AU"), ("en4", "Moira", "en-IE"), ("en5", "Rishi", "en-IN"), ("de2", "Markus", "de-DE"),
        ]
        let de = VoiceChoice.available(packReady: false, spokenLanguage: "de", system: { sys })
        #expect(de.map(\.id) == ["de1", "de2", "en1", "en2", "en3", "en4", "en5"])
        #expect(de.count >= 6)
        let en = VoiceChoice.available(packReady: false, spokenLanguage: "en", system: { sys })
        #expect(en.map(\.id) == ["en1", "en2", "en3", "en4", "en5"])
    }

    @Test func speedLabel() {
        #expect(VoiceChoice.rateLabel(1.0) == "1")
        #expect(VoiceChoice.rateLabel(1.25) == "1.25")
        #expect(VoiceChoice.rateLabel(0.75) == "0.75")
        #expect(VoiceChoice.rateLabel(1.5) == "1.5")
        #expect(VoiceChoice.rateLabel(1.0999) == "1.1")
    }

    @Test func spokenLanguageListIsTheUnion() {
        let codes = Set(SpokenLanguageChoice.all.map(\.code))
        #expect(SpokenLanguages.parakeet.isSubset(of: codes))
        #expect(["ja", "zh", "ar", "hi", "ko", "th"].allSatisfy(codes.contains))
        #expect(codes.count == SpokenLanguages.all.count && codes.count >= 100)
    }

    @Test func registryHasEverySection5Row() {
        for id in ["voiceInputDevice", "voiceSpokenLanguage", "voiceID", "voiceRate", "voiceMode", "voice.recordings"] {
            let row = SettingsRegistry.row(id)
            #expect(row?.section == .capabilities && row?.enabled == true, "\(id)")
        }
        #expect(SettingsRegistry.row("voice.later") == nil)
        #expect(!SettingsSearch.results("Spoken language").isEmpty)
    }
}
}
