// AT-100 unit legs (M1.T22; R-100): the six pages in sidebar order, every registered row found by its
// label (Settings search and ⌘K), every keyed row backed by a Keys.swift key with a default and vice versa,
// instant save (no Apply), the `-key YES` launch-override fix for every Bool key (step 8), and ⌘K/footer
// requests opening Settings at their row (AT-012 leg 2 model half).
import AntiChatDesign
import Defaults
import Foundation
import Testing
@testable import AntiChatUI

// Serialized with the window suites: SettingsKeys.resetAll() here must not race tests that set Defaults (M10 gate flake).
extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct SettingsRegistryTests {
    @Test func sectionsAreTheSixPagesInSidebarOrder() {
        #expect(SettingsSection.allCases.map { $0.title.string() } == [
            "General", "Capabilities", "Connections", "Skills", "Personalization", "Privacy & Data",
        ])
        for section in SettingsSection.allCases {
            #expect(!SettingsRegistry.rows(in: section).isEmpty, "\(section) would be an empty pane")
        }
    }

    @Test func everyRowHasCopyAndAUniqueID() {
        let ids = SettingsRegistry.rows.map(\.id)
        #expect(Set(ids).count == ids.count)
        for row in SettingsRegistry.rows {
            #expect(row.label.string() != row.label.rawValue, "missing copy for \(row.label.rawValue)")
            #expect(row.requirement.hasPrefix("R-"))
        }
    }

    @Test func searchFindsEveryRowByItsLabel() {
        for row in SettingsRegistry.rows {
            let label = row.label.string()
            #expect(SettingsSearch.results(label).contains { $0.id == row.id }, "Settings search misses \(row.id)")
        }
        #expect(SettingsSearch.results("").isEmpty)
        #expect(SettingsSearch.results("zzqqxx").isEmpty)
        #expect(SettingsSearch.results("archive").first.map { $0.section } == .privacy)
    }

    /// Plain questions find the row: filler words are ignored, each word may start a title, description or synonym
    /// word, plurals and a typo are forgiven.
    @Test func searchUnderstandsPlainWords() {
        func first(_ q: String) -> String? { SettingsSearch.results(q).first?.id }
        #expect(first("delete my chats") == "deleteAll")
        #expect(first("delete all the chats") == "deleteAll")
        #expect(first("clear history") == "deleteAll")
        #expect(first("dark mode") == "colorMode")
        #expect(first("font size") == "textSize")
        #expect(first("how do I change the language") == "appLanguage")
        #expect(first("microphone") == "voiceInputDevice")
        #expect(first("spreadsheets") == "createFiles", "found by its description")
        #expect(first("gmail") == "connections")
        #expect(first("incognto") == "newChatsIncognito", "one typo")
        #expect(SettingsSearch.results("memories").prefix(3).contains { $0.id == "manageMemories" })
        #expect(SettingsSearch.results("my the a").isEmpty)
    }

    /// Rows inside Advanced stay out of the way: listed only when nothing on a page matches or the query names them,
    /// and always after the rows on the page. The bare "Advanced" disclosure is never a result.
    @Test func searchKeepsAdvancedRowsBack() {
        let model = SettingsSearch.results("model")
        #expect(!model.isEmpty && model.allSatisfy { !$0.advanced }, "\(model.map(\.id))")
        #expect(model.count <= 4)
        for q in ["model", "advanced", "adv"] {
            #expect(!SettingsSearch.results(q).contains { $0.label.string() == "Advanced" })
        }
        #expect(SettingsSearch.results("safe search").map(\.id) == ["safeSearch"], "nothing on a page matches both words")
        #expect(SettingsSearch.results("memory").prefix(2).allSatisfy { !$0.advanced }, "the page's rows come first")
        #expect(SettingsSearch.results("reset memory").contains { $0.id == "resetMemory" }, "named, so listed")
        #expect(SettingsSearch.results("keep models loaded").first?.id == "keepLoadedMinutes")
        #expect(SettingsSearch.results("crash").first?.id == "crashReports", "nothing on a page matches")
        #expect(SettingsSearch.results("notifications").first?.id == "notifications")
        #expect(SettingsRegistry.row("capabilities.advanced") == nil)
    }

    @Test func paletteIndexIsTheRegistry() {
        SettingsRowsIndex.reset()
        #expect(SettingsRowsIndex.rows.map(\.id) == SettingsRegistry.rows.map(\.id))
    }

    @Test func keyedRowsAndKeysMatch() {
        let keys = SettingsKeys.defaults
        // `toolImage` / `toolVideo` have no row: they follow the Images and Video packs' switches.
        let keyed = SettingsRegistry.rows.compactMap(\.key) + ["toolImage", "toolVideo"]
        #expect(Set(keyed) == Set(keys.keys), "every key needs a row and every keyed row a key")
        #expect(keys["sendWithCommandEnter"] == "false")
        #expect(keys["menuBarItem"] == "true")
        #expect(keys["autoArchiveDays"] == "0")
        #expect(keys["stylePreset"] == "default")
        for row in SettingsRegistry.rows where row.key != nil {
            #expect(row.enabled, "\(row.id): a keyed M1 row is enabled")
        }
    }

    @Test func changesSaveInstantlyWithoutApply() {
        defer { SettingsKeys.resetAll() }
        Defaults[.plainTextComposer] = true
        #expect(UserDefaults.antichat.object(forKey: "plainTextComposer") as? Bool == true)
        Defaults[.autoArchiveDays] = 30
        #expect(UserDefaults.antichat.integer(forKey: "autoArchiveDays") == 30)
        Defaults[.stylePreset] = "candid"
        #expect(UserDefaults.antichat.string(forKey: "stylePreset") == "candid")
    }

    /// Step 8 (A-M1-T18a (l)): `-key YES` sits in NSArgumentDomain as a string; after `normalize()` every Bool key
    /// reads it as a boolean, and a stored value does not win over the launch argument.
    @Test func boolLaunchOverridesAreReadAsBooleans() {
        let d = UserDefaults.antichat  // the test's settings scope keeps its own argument domain (.isolatedSettings)
        let saved = d.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            d.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
            SettingsKeys.resetAll()
        }
        var args = saved
        args["sendWithCommandEnter"] = "YES"
        args["plainTextComposer"] = "YES"
        args["showContextUsage"] = "YES"
        args["menuBarItem"] = "NO"
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        #expect(Defaults[.showContextUsage] == false, "the unfixed bridge ignores the string (the bug)")
        let changed = DefaultsLaunchOverrides.normalize(defaults: d)
        #expect(changed == ["sendWithCommandEnter": true, "plainTextComposer": true, "showContextUsage": true,
                            "menuBarItem": false])
        #expect(Defaults[.sendWithCommandEnter] && Defaults[.plainTextComposer] && Defaults[.showContextUsage])
        #expect(Defaults[.menuBarItem] == false)
        Defaults[.showContextUsage] = false  // the stored value; the launch argument still wins this launch
        #expect(Defaults[.showContextUsage])
        #expect(DefaultsLaunchOverrides.normalize(defaults: d).isEmpty, "idempotent")
    }

    @Test func navigatorRequestsOpenSettingsAtTheRow() {
        let model = SettingsModel()
        _ = SettingsNavigator.shared.take()
        SettingsNavigator.shared.request(.general, row: "sendWithCommandEnter")
        model.query = "send"
        model.consume()
        #expect(model.selection == .general)
        #expect(model.highlightedRow == "sendWithCommandEnter")
        #expect(model.query.isEmpty)
        #expect(SettingsNavigator.shared.pending == nil)
        SettingsNavigator.shared.request(.privacy)
        model.consume()
        #expect(model.selection == .privacy)
        #expect(model.highlightedRow == nil)
        #expect(model.advancedOpen.isEmpty, "every page's Advanced group is collapsed by default")
    }

    /// Links written against the pages that were merged still land on the row, and a row inside Advanced opens it.
    @Test func aRowOpensOnItsOwnPageAndOpensAdvanced() {
        let model = SettingsModel()
        _ = SettingsNavigator.shared.take()
        SettingsNavigator.shared.request(.tools, row: "codeNet")
        model.consume()
        #expect(model.selection == .capabilities && model.highlightedRow == "codeNet")
        #expect(model.advancedOpen == [.capabilities])
        model.open(.general, row: "networkActivity")
        #expect(model.selection == .privacy && model.advancedOpen.contains(.privacy))
        model.open(.general, row: "updates.check")
        #expect(model.selection == .general && !model.advancedOpen.contains(.general), "the update card is on the page")
        for row in SettingsRegistry.rows where row.advanced {
            #expect(row.section != .connections && row.section != .skills, "\(row.id): these pages list no Advanced rows")
        }
    }
}
}
