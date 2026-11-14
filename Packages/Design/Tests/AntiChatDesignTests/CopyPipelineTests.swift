// Copy pipeline (M1.T03 step 5): the generated English table equals the generated Localizable.xcstrings, and
// CopyKey resolves + substitutes placeholders.
import Foundation
import Testing
@testable import AntiChatDesign

@Suite struct CopyPipelineTests {
    static let xcstrings = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "App/AntiChat/Localizable.xcstrings")

    @Test func tableMatchesStringCatalog() throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.xcstrings)) as! [String: Any]
        #expect(json["sourceLanguage"] as? String == "en")
        let strings = json["strings"] as! [String: [String: Any]]
        #expect(strings.count == CopyDeck.english.count)
        for (key, entry) in strings {
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            if let plural = CopyDeck.plurals[key] {
                // M9.T04: count strings are plural variations; `other` is the deck string with %lld for the count.
                let forms = (en?["variations"] as? [String: Any])?["plural"] as? [String: [String: [String: String]]]
                let other = CopyDeck.english[key]?.replacingOccurrences(of: "{\(plural.arg)}", with: "%lld")
                #expect(forms?["other"]?["stringUnit"]?["value"] == other, "\(key)")
            } else {
                let unit = en?["stringUnit"] as? [String: String]
                #expect(unit?["value"] == CopyDeck.english[key], "\(key)")
            }
        }
    }

    /// M9.T04 step 5: count strings pick the singular for 1 and keep the caller's number formatting.
    @Test func pluralForms() {
        #expect(CopyText(CopyKey("tile.pages"), ["count": "1"]).string == "1 page")
        #expect(CopyText(CopyKey("tile.pages"), ["count": "12"]).string == "12 pages")
        #expect(CopyText(CopyKey("composer.pasteCard"), ["count": "1"]).string == "Pasted text · 1 character")
        #expect(CopyText(CopyKey("set.privacy.autoArchive.days"), ["days": "30"]).string == "After 30 days")
        // a count string with a second placeholder: the singular still substitutes it
        #expect(CopyText(CopyKey("act.searched.region"), ["count": "1", "region": "DE"]).string
                == "Searched the web · 1 source · region hint DE")
        #expect(CopyText(CopyKey("act.searched.region"), ["count": "3", "region": "DE"]).string
                == "Searched the web · 3 sources · region hint DE")
        #expect(CopyKey.count("1,204") == 1204)
        #expect(CopyKey.count("none") == nil)
    }

    /// F8 (round 66, vq-m9 s25-not-enough-memory): the error offers only [Retry], so its copy asks for what Retry
    /// does (free memory, then try again), never "pick a smaller size" (the app already falls back to a lighter
    /// model before it refuses: MemoryFitGuard `usingLighter`).
    @Test func notEnoughMemoryCopyMatchesItsRetryAction() {
        let s = CopyKey("model.notEnoughMemory").string()
        #expect(s == "Not enough free memory right now. Close some apps, then try again.")
        #expect(!s.contains("smaller"))
    }

    @Test func resolvesAndSubstitutes() {
        #expect(CopyKey("side.newChat").string() == "New chat")
        #expect(CopyKey("ctx.usage").string(["percent": "42"]) == "42% of context used")
        #expect(CopyText(CopyKey("composer.pasteCard"), ["count": "1,204"]).string == "Pasted text · 1,204 characters")
        #expect(CopyKey("tool.loopLimit").string() == "Stopped after several steps.")
    }

    @Test func unknownKeyIsVisible() {
        let unknown = "no.such.key"  // a variable, so copy-sync does not read it as a code key
        #expect(!CopyKey(unknown).isKnown)
        #expect(CopyKey(unknown).string() == unknown)
    }

    /// M1.T03 step 6: the M1 key batch (A-M1-T03a) is present.
    @Test func m1KeysPresent() {
        let keys = (1...5).map { "empty.headline.\($0)" } + (1...4).map { "sugg.chat.\($0)" }
            + (1...4).map { "status.verb.\($0)" }
            + ["composer.disclaimer", "composer.queuedPct", "composer.pasteCard", "msg.dislike.title", "msg.liked",
               "palette.filter.liked", "palette.tab.all", "palette.tab.actions", "palette.tab.chats",
               "palette.tab.settings", "chat.branchTitle", "ctx.summarised", "ctx.tooLarge", "ctx.usage",
               "incognito.personalized", "incognito.unpersonalized", "incognito.close.confirm", "chats.page.title",
               "archived.title", "set.privacy.archiveAll", "set.privacy.autoArchive", "deleteAll.type",
               "side.footer.help", "side.footer.report", "side.footer.updates", "think.tip.preset",
               "scroll.bottom.a11y", "add.disabled.enable", "engine.versionMismatch", "menu.file.newProject",
               "menu.file.newWindow", "menu.file.close", "menu.help.legal"]
        for k in keys {
            #expect(CopyKey(k).isKnown, "\(k)")
        }
    }
}
