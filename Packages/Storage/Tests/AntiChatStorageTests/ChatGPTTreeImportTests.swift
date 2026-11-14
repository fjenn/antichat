// AT-296 leg (2) (M1.T04): every fixture in fixtures/chats/chatgpt-export/ imports into the v1 schema with
// node count = non-hidden mapping nodes, every parent edge, the active leaf and the active path identical to its
// `*.expected.json` (format of M0.T11 step 1); the CTE `visiblePath` agrees with the leaf.
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite("ChatGPTTreeImportTests") struct ChatGPTTreeImportTests {
    static let required = ["chatgpt-export.json", "chatgpt-tree.json", "chatgpt-citations.json"]

    @Test func requiredFixturesPresent() {
        let names = Set(expectedFiles(in: ["chats/chatgpt-export"]).map { ($0 as NSString).lastPathComponent })
        for fixture in Self.required {
            let expected = fixture.replacingOccurrences(of: ".json", with: ".expected.json")
            #expect(names.contains(expected), "missing \(expected) under \(fixturesRoot.path)")
        }
    }

    @Test(arguments: expectedFiles(in: ["chats/chatgpt-export"]))
    func matchesExpected(expectedPath: String) throws {
        let expectedURL = fixturesRoot.appendingPathComponent(expectedPath)
        let expected = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: expectedURL)) as? [String: Any])
        let fixtureName = try #require(expected["fixture"] as? String)
        let fixtureURL = expectedURL.deletingLastPathComponent().appendingPathComponent(fixtureName)
        let want = (expected["conversations"] as? [[String: Any]] ?? []).map(TreeShape.init(expected:))

        let database = try AppDatabase.inMemory()
        let chatIDs = try ChatGPTTreeImporter.importConversations(Data(contentsOf: fixtureURL), into: database)
        #expect(chatIDs.count == want.count, "conversation count")
        let got = try database.read { db in try readShapes(db) }
        for expectedShape in want {
            let match = try #require(got.first { $0.shape.id == expectedShape.id }, "\(expectedShape.id) not imported")
            let diffs = match.shape.differences(from: expectedShape)
            #expect(diffs.isEmpty, "\(fixtureName) \(expectedShape.id): \(diffs)")
            #expect(match.downPath == match.shape.activePath, "active_child_id chain != parent_id path")
            #expect(match.ctePath == match.shape.activePath, "visiblePath CTE != parent_id path")
            #expect(match.emptyMessages == 0, "messages without a non-empty part")
        }
        try database.read { (db: Database) throws in
            #expect(try TreeInvariants.violations(db) == [])
            #expect(try String.fetchAll(db, sql: "SELECT DISTINCT source FROM chat") == ["chatgpt"])
        }
    }

    /// Version switching works on imported branches: every branch point reports ‹n/N› and can be activated.
    @Test func importedBranchesAreSwitchable() throws {
        let url = fixturesRoot.appendingPathComponent("chats/chatgpt-export/chatgpt-tree.json")
        let database = try AppDatabase.inMemory()
        let chatID = try #require(try ChatGPTTreeImporter.importConversations(Data(contentsOf: url), into: database).first)
        let tree = MessageTree(database)
        let forks = try database.read { (db: Database) throws in
            try String.fetchAll(db, sql: """
                SELECT id FROM message WHERE chat_id = ? AND parent_id IN
                  (SELECT parent_id FROM message WHERE chat_id = ? GROUP BY parent_id HAVING COUNT(*) > 1)
                ORDER BY parent_id, position
                """, arguments: [chatID, chatID])
        }
        #expect(forks.count >= 4)
        for id in forks {
            try tree.setActive(id)
            let path = try tree.visiblePath(chatID).map(\.id)
            #expect(path.contains(id))
            #expect(try tree.versionInfo(id).total >= 2)
            try expectValidTrees(database)
        }
    }

    @Test func toolResultsAreUntrustedAndUnknownFieldsIgnored() throws {
        let json = """
            [{"id": "t", "title": "tools", "current_node": "r", "unknown_top": {"x": 1}, "mapping": {
              "q": {"id": "q", "parent": null, "children": ["c"], "future_field": true,
                    "message": {"author": {"role": "user"}, "content": {"content_type": "text", "parts": ["search"]}}},
              "c": {"id": "c", "parent": "q", "children": ["r"],
                    "message": {"author": {"role": "tool", "name": "browser"},
                                "content": {"content_type": "tether_browsing_display", "result": "page"}}},
              "r": {"id": "r", "parent": "c", "children": [],
                    "message": {"author": {"role": "assistant"}, "content": {"content_type": "text", "parts": ["done"]}}}
            }}]
            """
        let database = try AppDatabase.inMemory()
        try ChatGPTTreeImporter.importConversations(Data(json.utf8), into: database)
        let rows = try database.read { (db: Database) throws in
            try Row.fetchAll(db, sql: """
                SELECT m.source_id, p.kind, p.untrusted FROM message m JOIN message_part p ON p.message_id = m.id
                ORDER BY m.position, m.source_id
                """)
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["source_id"] as String, $0) })
        // M8.T06 step 6: tool output is kept as text under `[Imported browsing result]`, still untrusted.
        #expect(byID["c"]?["kind"] == "text")
        #expect(byID["c"]?["untrusted"] == true)
        #expect(byID["r"]?["untrusted"] == false)
        #expect(throws: ImportError.unrecognizedFormat) {
            try ChatGPTTreeImporter.importConversations(Data(#"[{"x": 1}]"#.utf8), into: database)
        }
        #expect(throws: ImportError.invalidJSON) {
            try ChatGPTTreeImporter.importConversations(Data("not json".utf8), into: database)
        }
    }
}
