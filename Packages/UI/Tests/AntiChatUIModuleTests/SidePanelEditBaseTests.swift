// M6 review #11: Edit selection / Fix on an older version carries that version, so the new version records it as its
// parent (ArtifactStore.save(revisesVersion:)), not the newest.
import AntiChatFoundation
import AntiChatHarness
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct SidePanelEditBaseTests {
    @Test func editOnAnOlderVersionCarriesIt() throws {
        let dir = try FileFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = try (1...3).map { n -> String in
            let u = dir.appendingPathComponent("v\(n).md")
            try "version \(n) text".write(to: u, atomically: true, encoding: .utf8)
            return u.path
        }
        let panel = SidePanelModel(windowID: "base-\(UUID().uuidString)", defaults: UserDefaults.inMemory())
        var sent: [ArtifactEditRequest] = []
        panel.onArtifactEdit = { sent.append($0) }
        panel.open(.init(artifactID: "a", title: "notes.md", kind: .code, react: false, language: "md", version: 3,
                         versions: (1...3).map { (n: $0, path: paths[$0 - 1]) }, createdAt: Date(), versionCreatedAt: Date()))
        panel.select(version: 1)
        panel.selection = "version 1"
        panel.submitEditSelection(instruction: "say one")
        #expect(sent.last?.baseVersion == 1 && sent.last?.source == "version 1 text", "\(String(describing: sent.last))")
        panel.previewError = "boom"
        panel.fix()
        #expect(sent.last?.baseVersion == 1)
    }
}
