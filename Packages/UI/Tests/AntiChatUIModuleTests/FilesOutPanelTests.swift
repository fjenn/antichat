// M6.T13 (R-016 AC1/AC5, R-017 AC1/AC2, R-277 AC2): produced files open the window's side panel once by themselves
// (fresh call only, not a reloaded chat), the version chain goes to the panel picker, FileCard Copy puts the file URL
// on the pasteboard, a removed media-store file shows `file.deleted` with actions disabled, and the Outputs list keeps
// only produced files.
//   make test-unit FILTER=FilesOutPanelTests
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import AppKit
import Foundation
import Testing
@testable import AntiChatUI

@MainActor
@Suite(.serialized, .isolatedSettings) struct FilesOutPanelTests {
    static func result(path: String, version: Int = 1, versions: String = "") -> String {
        #"{"artifact_id":"a1","file":"Plan.pdf","format":"pdf","path":"\#(path)","size":10,"version":\#(version)\#(versions)}"# + "\nCreated."
    }

    @Test func autoOpenOnceForFreshCalls() {
        let fresh = ToolActivity(id: "c1", tool: "create_document", state: .done, argumentsJSON: "{}",
                                 result: Self.result(path: "/tmp/p/a.pdf"), seconds: 1, startedAt: Date().addingTimeInterval(-2))
        let old = ToolActivity(id: "c2", tool: "create_document", state: .done, argumentsJSON: "{}",
                               result: Self.result(path: "/tmp/p/b.pdf"), seconds: 1, startedAt: Date().addingTimeInterval(-3600))
        #expect(FileOutActivity.isFresh(fresh) && !FileOutActivity.isFresh(old))
        let panel = SidePanelModel(windowID: "t13-\(UUID())", defaults: UserDefaults.inMemory())
        let url = FileOutActivity.panelVersions(fresh).last?.url
        #expect(panel.autoOpenOnce(url) && !panel.autoOpenOnce(url), "one automatic open per file")
    }

    @Test func versionChainToPanel() {
        let chain = #","versions":[{"n":1,"path":"/tmp/p/v1.pdf","size":9},{"n":2,"path":"/tmp/p/v2.pdf","size":10}]"#
        let a = ToolActivity(id: "c1", tool: "create_document", state: .done, argumentsJSON: "{}",
                             result: Self.result(path: "/tmp/p/v2.pdf", version: 2, versions: chain))
        let v = FileOutActivity.panelVersions(a)
        #expect(v.map(\.n) == [1, 2] && v.last?.url.path == "/tmp/p/v2.pdf")
        let panel = SidePanelModel(windowID: "t13v-\(UUID())", defaults: UserDefaults.inMemory())
        panel.open(title: "Plan.pdf", versions: v, selecting: 2)
        #expect(panel.isOpen && panel.current?.n == 2 && panel.versionLabel != nil)
    }

    @Test func copyAndDeletedState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("t13-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("abc.pdf")
        try Data("%PDF".utf8).write(to: url)
        let m = FileCardViewModel(item: FileCardItem(url: url, displayName: "report.pdf", size: 4))
        #expect(m.actionsEnabled && !m.isDeleted)
        m.copy()
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]
        #expect(urls?.first?.lastPathComponent == "report.pdf", "a copy named display_name on the pasteboard, not the blob")
        #expect(try urls.flatMap { $0.first }.map { try Data(contentsOf: $0) } == Data("%PDF".utf8))
        try FileManager.default.removeItem(at: url)
        let gone = FileCardViewModel(item: FileCardItem(url: url, displayName: "report.pdf", size: 4))
        #expect(gone.isDeleted && !gone.actionsEnabled && gone.subtitle.contains("File deleted"))
    }

    @Test func outputsKeepsProducedOnly() {
        let now = Date()
        let files = [ChatFile(id: "1", origin: .attached, name: "in.pdf", kind: "com.adobe.pdf", size: 1, date: now, path: "/x", version: nil),
                     ChatFile(id: "2", origin: .produced, name: "out.xlsx", kind: "xlsx", size: 2, date: now, path: "/y", version: 1)]
        #expect(OutputsListView(files: files, onSelect: { _ in }).files.map(\.name) == ["out.xlsx"])
        #expect(ChatFileRow.kindLabel(files[0]) == "PDF" && ChatFileRow.subtitle(files[1]).hasPrefix("XLSX · "))
    }
}
