// M8.T06 AT-092 (R-092 AC1/AC3) on `claude-export/export.zip`: the three synthetic-branches conversations keep
// their branches (`parent_message_uuid`), active leaf and `sender`/`role` variants (synthetic-branches.expected.json);
// the fourth keeps its two attachments' `extracted_content` and the tool_use / tool_result pair as `[Imported …]`
// text (tool output untrusted), counted per type.
//   make test-unit FILTER=ClaudeImportTests
import Foundation
import GRDB
import Testing
@testable import AntiChatStorage

@Suite(.serialized) struct ClaudeImportTests {
    @Test func exportZipKeepsBranchesAttachmentsAndTools() throws {
        let rig = try ImportRig()
        defer { rig.cleanup() }
        let zip = importFixture("chats/claude-export/export.zip")
        #expect(ChatImporter.detect(zip) == .claude)
        let s = try rig.importer.run(zip)
        #expect(s.format == .claude && s.chats == 4)
        #expect(s.kept["attachment"] == 2 && s.kept["tool use"] == 1 && s.kept["tool result"] == 1)
        let exp = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: importFixture("chats/claude-export/synthetic-branches.expected.json"))) as? [String: Any])
        for c in exp["conversations"] as? [[String: Any]] ?? [] {
            let id = try #require(c["id"] as? String)
            let row = try #require(try rig.db.read { try Row.fetchOne($0, sql: """
                SELECT c.source, (SELECT COUNT(*) FROM message m WHERE m.chat_id = c.id) AS n,
                       (SELECT m.source_id FROM message m WHERE m.id = c.leaf_message_id) AS leaf
                FROM chat c WHERE c.source_id = ?
                """, arguments: [id]) })
            #expect(row["source"] == "claude")
            #expect(row["n"] == c["nodes"] as? Int)
            #expect(row["leaf"] == c["active_leaf"] as? String)
            let edges = try rig.db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT m.source_id AS s, p.source_id AS p FROM message m LEFT JOIN message p ON p.id = m.parent_id
                    JOIN chat c ON c.id = m.chat_id WHERE c.source_id = ?
                    """, arguments: [id])
            }
            let got = Dictionary(uniqueKeysWithValues: edges.map { ($0["s"] as String, $0["p"] as String?) })
            for e in c["edges"] as? [[Any]] ?? [] {
                let child = e[0] as? String ?? "", parent = e[1] as? String
                #expect(got[child] == .some(parent), "edge \(child)")
            }
        }
        let parts = try rig.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT p.body, p.untrusted FROM message_part p JOIN message m ON m.id = p.message_id JOIN chat c ON c.id = m.chat_id
                WHERE c.title = 'Attachments and a tool'
                """)
        }
        #expect(parts.contains { ($0["body"] as String).hasPrefix("[Imported attachment notes-a.txt]") && ($0["body"] as String).contains("1240 degrees") })
        #expect(parts.contains { ($0["body"] as String).hasPrefix("[Imported tool use]") && ($0["body"] as String).contains("web_search") })
        #expect(parts.contains { ($0["body"] as String).hasPrefix("[Imported tool result]") && ($0["untrusted"] as Bool) })
    }
}
