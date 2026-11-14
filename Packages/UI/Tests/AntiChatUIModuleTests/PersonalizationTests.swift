// AT-062 unit legs (M1.T22 step 4; R-062): (1) both text areas take 3,000 characters and refuse the 3,001st
// (counter 3000/3000); 6 style presets and 4 characteristics with More / Default / Less; (2) the settings reach the
// rendered prompt of a new Normal and a new Evil turn (layer 3), not an incognito Unpersonalized turn, and do reach
// an incognito Personalized turn. Prompt texts go to `$ANTICHAT_AT_OUT/prompts/` when set (AT-062 evidence).
import AntiChatDesign
import AntiChatHarness
import Defaults
import Foundation
import Testing
@testable import AntiChatUI

// Serialized with the window suites: SettingsKeys.resetAll() here must not race tests that set Defaults (M10 gate flake).
extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct PersonalizationTests {
    @Test func textAreasRefuseThe3001stCharacter() {
        let full = String(repeating: "a", count: 3000)
        #expect(Personalization.clamp(full) == full)
        #expect(Personalization.clamp(full + "b").count == 3000)
        #expect(Personalization.clamp(full + "b") == full)
        #expect(CopyText(CopyKey("set.pers.counter"), ["count": "3000", "max": "\(Personalization.maxChars)"]).string
                == "3000/3000")
        defer { SettingsKeys.resetAll() }
        Defaults[.aboutYou] = full + "xyz"  // a stored over-long value is clamped where it is used
        #expect(PersonalizationSync.current().aboutYou.count == 3000)
    }

    @Test func presetsAndCharacteristicsExist() {
        #expect(Personalization.StylePreset.allCases.map { CopyKey("set.pers.style.\($0.rawValue)").string() }
                == ["Default", "Professional", "Friendly", "Candid", "Efficient", "Quirky"])
        #expect(Personalization.Level.allCases.map { CopyKey("set.pers.level.\($0.rawValue)").string() }
                == ["More", "Default", "Less"])
        let characteristics = ["warmth", "enthusiasm", "headersAndLists", "emoji"]
        #expect(characteristics.map { SettingsRegistry.row($0)?.label.string() }
                == ["Warmth", "Enthusiasm", "Headers & lists", "Emoji"])
        for id in characteristics + ["aboutYou", "howToRespond", "stylePreset"] {
            #expect(SettingsRegistry.row(id)?.section == .personalization)
        }
    }

    @Test func settingsReachTheInstructionLayerOfEveryTurnKind() throws {
        defer { SettingsKeys.resetAll() }
        let settings = PromptSettings()
        let sync = PersonalizationSync(settings)
        #expect(settings.inputs.personalization == .none)
        Defaults[.aboutYou] = "I am a marine biologist in Lisbon."
        Defaults[.howToRespond] = "Answer in short paragraphs."
        Defaults[.stylePreset] = "candid"
        Defaults[.emoji] = "less"
        let p = settings.inputs.personalization
        #expect(p.aboutYou == "I am a marine biologist in Lisbon.")
        #expect(p.style == .candid && p.emoji == .less)

        let composer = PromptComposer()
        func system(_ mode: PromptMode, _ incognito: IncognitoPersonalization?) -> (String, Bool) {
            let c = composer.compose(settings.inputs.forTurn(mode: mode, incognito: incognito))
            return (c.systemText, c.layers.contains { $0.id == PromptLayerID.instructions })
        }
        let normal = system(.normal, nil)
        let evil = system(.evil(toneSentence: "Be blunt."), nil)
        let unpersonalized = system(.normal, .unpersonalized)
        let personalized = system(.normal, .personalized)
        #expect(normal.1 && normal.0.contains("marine biologist") && normal.0.contains("short paragraphs"))
        #expect(evil.1 && evil.0.contains("marine biologist") && evil.0.contains("Be blunt."))
        #expect(!unpersonalized.1 && !unpersonalized.0.contains("marine biologist"))
        #expect(personalized.1 && personalized.0.contains("marine biologist"))

        if let out = ProcessInfo.processInfo.environment["ANTICHAT_AT_OUT"] {
            let dir = URL(fileURLWithPath: out).appendingPathComponent("prompts", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, s) in [("normal", normal.0), ("evil", evil.0), ("incognito-unpersonalized", unpersonalized.0),
                              ("incognito-personalized", personalized.0)] {
                try s.write(to: dir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            }
        }
        _ = sync
    }
}
}
