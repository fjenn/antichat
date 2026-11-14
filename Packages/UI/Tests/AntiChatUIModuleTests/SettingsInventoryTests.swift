// M4.T03 / AT-285 AC6: no Defaults key, settings row, search entry or launch argument mentions or controls the
// ChildSafetyCheck (D-006: "No setting"). "Safe search results" (the M7 search-engine option) is not the check.
import AntiChatDesign
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct SettingsInventoryTests {
    static let forbidden = try! Regex("(?i)child|csam|minor|nsfw|nudity|safety[ _.-]?check|age[ _-]?estimat|ChildSafety")

    @Test func testNoChildSafetySetting() {
        for row in SettingsRegistry.rows {
            let text = [row.id, row.key ?? "", row.label.rawValue, row.label.string(), row.defaultText] + row.keywords
            for t in text { #expect(t.firstMatch(of: Self.forbidden) == nil, "settings row \(row.id): '\(t)'") }
        }
        for key in SettingsKeys.defaults.keys {
            #expect(key.firstMatch(of: Self.forbidden) == nil, "Defaults key \(key)")
        }
        for key in LaunchOptions.Key.allCases {
            #expect(key.rawValue.firstMatch(of: Self.forbidden) == nil, "launch argument \(key.rawValue)")
            #expect(!key.rawValue.contains("SafetyVerdict"), "the forced verdict is a UI-testing build seam only")
        }
        // Settings search for "safety" finds nothing that touches the check (safe search is a search-engine option).
        for row in SettingsRegistry.rows where "\(row.label.string()) \(row.keywords.joined(separator: " "))".localizedCaseInsensitiveContains("safety") {
            #expect(row.id.localizedCaseInsensitiveContains("safeSearch"), "\(row.id)")
        }
    }
}
