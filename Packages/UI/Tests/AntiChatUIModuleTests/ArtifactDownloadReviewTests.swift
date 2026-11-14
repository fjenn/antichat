// M6 review #17: Download never fails silently. A web format with no rendered preview reports `.failed` (the panel
// shows a toast); a cancelled save panel is `.cancelled`; a written file is `.saved`.
import AntiChatDesign
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import AntiChatUI

@MainActor
@Suite(.isolatedSettings) struct ArtifactDownloadReviewTests {
    @Test func failuresAreReported() async throws {
        let dir = try FileFixtures.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = dir.appendingPathComponent("page.html")
        try "<p>hi</p>".write(to: html, atomically: true, encoding: .utf8)
        let noWeb = await ArtifactExport.download(.pdf, title: "page.html", url: html, preview: .html, language: "html",
                                                  web: nil, choose: { _, _ in dir.appendingPathComponent("x.pdf") })
        #expect(noWeb == .failed)
        #expect(ArtifactExport.toast(for: noWeb) != nil, "the panel shows a toast")
        let unsandboxed = SandboxedWebController(fileURL: html, mode: .html, rules: nil)
        #expect(await ArtifactExport.download(.png, title: "page.html", url: html, preview: .html, language: "html",
                                              web: unsandboxed, choose: { _, _ in dir.appendingPathComponent("x.png") }) == .failed)
        #expect(await ArtifactExport.download(.html, title: "page.html", url: html, preview: .html, language: "html",
                                              web: nil, choose: { _, _ in nil }) == .cancelled)
        let dest = dir.appendingPathComponent("saved.html")
        #expect(await ArtifactExport.download(.html, title: "page.html", url: html, preview: .html, language: "html",
                                              web: nil, choose: { _, _ in dest }) == .saved(dest))
        #expect(ArtifactExport.toast(for: .saved(dest)) == nil && ArtifactExport.toast(for: .cancelled) == nil)
        let unwritable = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.html")
        #expect(await ArtifactExport.download(.html, title: "page.html", url: html, preview: .html, language: "html",
                                              web: nil, choose: { _, _ in unwritable }) == .failed)
    }
}
