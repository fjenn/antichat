// Q-015 XCUITest catch-up: main-menu items get their copy key as accessibility identifier (SwiftUI leaves the
// action selector `menuAction:`).
import AppKit
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct MenuItemIdentifiersTests {
    @Test func itemsWithACopyTitleGetTheirKey() {
        let menu = NSMenu(title: "File")
        let evil = NSMenuItem(title: CopyKey("menu.file.newEvilChat").string(), action: nil, keyEquivalent: "")
        let other = NSMenuItem(title: "Something else", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Sub")
        let nested = NSMenuItem(title: CopyKey("menu.file.newChat").string(), action: nil, keyEquivalent: "")
        sub.addItem(nested)
        let holder = NSMenuItem(title: "Holder", action: nil, keyEquivalent: "")
        holder.submenu = sub
        [evil, other, holder].forEach(menu.addItem)
        MenuItemIdentifiers.apply(to: menu)
        #expect(evil.identifier?.rawValue == "menu.file.newEvilChat")
        #expect(nested.identifier?.rawValue == "menu.file.newChat")
        #expect(other.identifier == nil)
    }

    @Test func titlesSkipStringsWithArguments() {
        #expect(MenuItemIdentifiers.titles.values.allSatisfy { !CopyKey($0).string().contains("{") })
        #expect(MenuItemIdentifiers.titles[CopyKey("menu.file.newEvilChat").string()] == "menu.file.newEvilChat")
    }
}
