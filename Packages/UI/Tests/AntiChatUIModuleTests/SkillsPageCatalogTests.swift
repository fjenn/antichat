// Settings › Skills follows the skills index: the page reads `SkillsCatalog.shared` again when `DirectoryCatalogs`
// says a newer index arrived, and only then (not for the apps list's post, not for a fixed catalogue).
//   make test-unit FILTER=SkillsPageCatalogTests
@testable import AntiChatUI
import AntiChatTools
import Foundation
import Testing

@Suite struct SkillsPageCatalogTests {
    private func note(_ kind: String?) -> Notification {
        Notification(name: DirectoryCatalogs.didChange, object: nil, userInfo: kind.map { ["kind": $0] })
    }

    @MainActor @Test func thePageReadsTheCatalogueAgainWhenANewerIndexArrives() {
        #expect(SkillsPage.shouldReload(note(DirectoryCatalogs.Kind.skills.rawValue), followsLive: true))
        #expect(!SkillsPage.shouldReload(note(LiveAppCatalog.kind), followsLive: true))  // the apps list changed
        #expect(!SkillsPage.shouldReload(note(nil), followsLive: true))
        // A page drawn from a fixed catalogue (snapshots) keeps it.
        #expect(!SkillsPage.shouldReload(note(DirectoryCatalogs.Kind.skills.rawValue), followsLive: false))
    }
}
