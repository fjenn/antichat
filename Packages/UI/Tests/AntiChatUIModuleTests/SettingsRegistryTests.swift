// AT-100 unit legs (M1.T22; R-100): the 13 sections in settings-map order, every registered row found by its
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
    @Test func sectionsAreTheThirteenInSettingsMapOrder() {
        #expect(SettingsSection.allCases.map { $0.title.string() } == [
            "General", "Appearance", "Capabilities", "Evil Mode", "Voice", "Personalization", "Tools & Connections",
            "Skills", "Privacy & Data", "Storage", "Updates", "Keyboard shortcuts", "About & Help",
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
            #expect(SettingsRowsProvider.rows(matching: label).contains { $0.id == "setting.\(row.id)" },
                    "⌘K misses \(row.id)")
        }
        #expect(SettingsSearch.results("").isEmpty)
        #expect(SettingsSearch.results("zzqqxx").isEmpty)
        #expect(SettingsSearch.results("archive").first.map { $0.section } == .privacy)
    }

    @Test func paletteIndexIsTheRegistry() {
        SettingsRowsIndex.reset()
        #expect(SettingsRowsIndex.rows.map(\.id) == SettingsRegistry.rows.map(\.id))
    }

    @Test func keyedRowsAndKeysMatch() {
        let keys = SettingsKeys.defaults
        let keyed = SettingsRegistry.rows.compactMap(\.key)
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
        SettingsNavigator.shared.request(.updates)
        model.consume()
        #expect(model.selection == .updates)
        #expect(model.highlightedRow == nil)
        #expect(!model.advancedExpanded, "Capabilities → Advanced is collapsed by default")
    }
}
}
