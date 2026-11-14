// AT-296 leg (3) (M1.T04): exportJSON → importJSON → exportJSON is structurally equal (ids normalised) for every
// fixture chat, including the imported ones.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite("TreeRoundTripTests") struct TreeRoundTripTests {
    /// Exports `chatID`, imports the export, exports again; both exports must match after id normalisation.
    private func assertRoundTrip(_ chatID: String, in database: AppDatabase, _ label: String) throws {
        let first = try TreeExport.exportJSON(chatID, from: database)
        let copyID = try TreeExport.importJSON(first, into: database)
        #expect(copyID != chatID)
        let second = try TreeExport.exportJSON(copyID, from: database)
        let a = try normalizedExport(first)
        let b = try normalizedExport(second)
        let nodeDiffs = zip(a.nodes, b.nodes).enumerated().filter { $0.element.0 != $0.element.1 }
            .map { "node \($0.offset): \($0.element.0) != \($0.element.1)" }
        #expect(a == b, "\(label): round trip changed the tree; chat equal \(a.chat == b.chat), leaf \(a.leafID ?? "nil") vs \(b.leafID ?? "nil"), counts \(a.nodes.count)/\(b.nodes.count), \(nodeDiffs.prefix(2))")
        // Fresh ids: no node id of the copy appears in the original.
        let originalIDs = Set(try TreeExportDocument.decoder().decode(TreeExportDocument.self, from: first).nodes.map(\.id))
        let copyIDs = Set(try TreeExportDocument.decoder().decode(TreeExportDocument.self, from: second).nodes.map(\.id))
        #expect(originalIDs.isDisjoint(with: copyIDs), "\(label): ids not remapped")
        // The copy's tree reads back with the same visible path (in normalised ids).
        let pathA = try database.read { db in try MessageTree.visiblePath(chatID, db: db).count }
        let pathB = try database.read { db in try MessageTree.visiblePath(copyID, db: db).count }
        #expect(pathA == pathB, "\(label): visible path length")
    }

    @Test func treeBasicWithVersions() throws {
        let f = try TreeFixtures.treeBasic()
        let tree = MessageTree(f.database)
        for i in 1...3 { _ = try tree.insertSibling(of: f.ids[5], parts: [.text("take \(i)")]) }
        let edit = try tree.insertSibling(of: f.ids[2], parts: [.text("edit")])
        try tree.append(chatID: f.chatID, parentID: edit.id, role: .assistant, parts: [
            PartContent(kind: .reasoning, body: "thinking"), .text("reply"),
            PartContent(kind: .toolResult, body: #"{"ok":true}"#, untrusted: true),
        ]) {
            $0.usage = MessageUsage(promptTokens: 12, completionTokens: 34)
            $0.summaryOfIDs = [f.ids[0], f.ids[1]]
        }
        try tree.setActive(f.ids[3])  // leave the active path on the original branch
        let document = try f.database.read { db in try TreeExport.document(f.chatID, db: db) }
        #expect(document.nodes.count == 6 + 3 + 2)
        #expect(document.schema == "antichat.tree.v1")
        try assertRoundTrip(f.chatID, in: f.database, "tree-basic")
        try expectValidTrees(f.database)
    }

    @Test(arguments: importFixtureFiles())
    func importedFixtures(fixture: URL) throws {
        let database = try AppDatabase.inMemory()
        let chatIDs = try TreeImporter.importExport(data: Data(contentsOf: fixture), into: database)
        #expect(!chatIDs.isEmpty)
        for chatID in chatIDs { try assertRoundTrip(chatID, in: database, "\(fixture.lastPathComponent) \(chatID)") }
        try expectValidTrees(database)
    }

    @Test func fixturesPresent() {
        #expect(importFixtureFiles().count >= 4, "fixtures root \(fixturesRoot.path)")
    }

    @Test func importRejectsBrokenDocuments() throws {
        let database = try AppDatabase.inMemory()
        #expect(throws: StorageError.self) { try TreeExport.importJSON(Data("{}".utf8), into: database) }
        let f = try TreeFixtures.treeBasic(database)
        var document = try database.read { db in try TreeExport.document(f.chatID, db: db) }
        document.schema = "other"
        let encoded = try TreeExportDocument.encoder().encode(document)
        #expect(throws: StorageError.self) { try TreeExport.importJSON(encoded, into: database) }
        document.schema = TreeExportDocument.schemaID
        document.nodes.swapAt(0, 1)  // child before parent
        #expect(throws: StorageError.self) {
            try TreeExport.importJSON(TreeExportDocument.encoder().encode(document), into: database)
        }
        document.nodes.swapAt(0, 1)
        document.nodes[0].activeChildID = document.nodes[3].id  // not its child
        #expect(throws: StorageError.self) {
            try TreeExport.importJSON(TreeExportDocument.encoder().encode(document), into: database)
        }
        #expect(throws: StorageError.self) { try TreeExport.exportJSON("missing", from: database) }
    }
}
