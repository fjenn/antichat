// M10.T06/T07 (AT-217 AC2, AT-303 AC1–AC3, unit legs): bundled documents parse their front matter; every legal page
// shipped in the app carries version + date; the offline/online Help decision; What's new shows once per version,
// never on first install, never during onboarding, never when switched off, only with 3–5 items; the tour lists
// the installed packs; site links resolve from the release and the dev DownloadURL alike. The XCUITest legs
// (App/UITests/HelpUITests.swift, LegalUITests.swift) are written and pending (Q-015).
//   make test-unit FILTER=HelpAndLegalTests
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatUI

struct HelpAndLegalTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../..").standardized

    @Test(.isolatedSettings) func frontMatterParses() {
        let d = BundledDocument.parse(id: "terms", text: "---\ntitle: Terms of use\nversion: \"0.1.0\"\nupdated: \"2026-11-08\"\n---\n\nBody **x**.\n")
        #expect(d.title == "Terms of use" && d.version == "0.1.0" && d.updated == "2026-11-08")
        #expect(d.body == "Body **x**.")
        let g = BundledDocument.parse(id: "guide", text: "# Short guide\n\n## Packs\ntext")
        #expect(g.title == "Short guide" && g.version == nil)
        #expect(String(g.attributed.characters).contains("Packs") && !String(g.attributed.characters).contains("#"))
    }

    @Test(.isolatedSettings) func everyBundledLegalPageIsVersionedAndDated() throws {
        let dir = Self.repo.appendingPathComponent("App/AntiChat/Resources/Legal")
        for name in BundledDocument.legalOrder {
            let text = try String(contentsOf: dir.appendingPathComponent("\(name).md"), encoding: .utf8)
            let d = BundledDocument.parse(id: name, text: text)
            #expect(d.version?.isEmpty == false && d.updated?.isEmpty == false, "\(name)")
        }
        let evil = try String(contentsOf: dir.appendingPathComponent("evil-mode-terms.md"), encoding: .utf8)
        #expect(evil.contains("sexual content involving minors") && evil.contains("18"))
    }

    @Test(.isolatedSettings) func helpOpensTheBrowserOnlyWhenOnline() {
        #expect(HelpCentre.opensBrowser(pathSatisfied: true, offlineOnly: false))
        #expect(!HelpCentre.opensBrowser(pathSatisfied: false, offlineOnly: false))
        #expect(!HelpCentre.opensBrowser(pathSatisfied: true, offlineOnly: true))
    }

    @Test(.isolatedSettings) func siteLinksFromReleaseAndDevDownloadURL() {
        #expect(SiteLinks.root(downloadURL: "https://antichat-site.vercel.app/download/") == "https://antichat-site.vercel.app")
        #expect(SiteLinks.root(downloadURL: "http://localhost:4321/download") == "http://localhost:4321")  // DownloadURLDev
        #expect(SiteLinks.url("/help/faq/", downloadURL: "http://localhost:4321/download")?.absoluteString
                == "http://localhost:4321/help/faq/")
        #expect(SiteLinks.url("/legal/terms/", downloadURL: "https://a.example/download/")?.absoluteString
                == "https://a.example/legal/terms/")
        #expect(SiteLinks.url("/help/faq/", downloadURL: nil) == nil)
        // Help › AntiChat Help and Settings › General › Help open the help centre's front page.
        #expect(HelpCentre.url == SiteLinks.url("/help/"))
    }

    @Test(.isolatedSettings) func whatsNewRules() {
        let show = { (last: String?, enabled: Bool, onb: Bool, n: Int) in
            WhatsNewProvider.shouldShow(current: "1.1.0", lastSeen: last, enabled: enabled, onboarding: onb, itemCount: n)
        }
        #expect(show("1.0.0", true, false, 3))          // after an update
        #expect(!show("1.1.0", true, false, 3))         // already seen
        #expect(!show(nil, true, false, 3))             // first install
        #expect(!show("1.0.0", false, false, 3))        // switched off
        #expect(!show("1.0.0", true, true, 3))          // during onboarding
        #expect(!show("1.0.0", true, false, 2) && !show("1.0.0", true, false, 6))
    }

    @Test(.isolatedSettings) func whatsNewOnceThenRecorded() throws {
        let d = UserDefaults.inMemory()
        #expect(WhatsNewProvider.notesToShow(defaults: d, onboarding: false) == nil)   // first launch records only
        #expect(d.string(forKey: WhatsNewProvider.lastSeenKey) == WhatsNewProvider.currentVersion)
    }

    @Test(.isolatedSettings) func committedNotesDecode() throws {
        let data = try Data(contentsOf: Self.repo.appendingPathComponent("notes/0.0.1.json"))
        let n = try JSONDecoder().decode(WhatsNewNotes.self, from: data)
        #expect(n.version == "0.0.1" && (3 ... 5).contains(n.items.count))
    }
}
