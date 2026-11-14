// M6.T09 task check `SpecValidatorTests` (AT-273 check 2, R-273 AC2): the JSON Schema subset the file-out specs and the
// tool loop share, the create_document semantic checks (image refs, remote images), the `{"repair": true}` text, and
// the full call path: render → artifact + artifact_version(n: 1) + file_blob(origin: generated) → result summary.
import AntiChatStorage
import Foundation
import GRDB
import Testing
@testable import AntiChatTools

@Suite struct SpecValidatorTests {
    static func schema(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func keywords() {
        let s = Self.schema(#"{"type":"object","properties":{"n":{"type":"integer","minimum":1,"maximum":3},"s":{"type":"string","minLength":2,"maxLength":4},"a":{"type":"array","minItems":1,"maxItems":2,"items":{"type":"string"}},"e":{"enum":["x","y"]},"o":{"oneOf":[{"type":"string"},{"type":"integer"}]}},"required":["n"],"additionalProperties":false}"#)
        #expect(SpecValidator.problems(["n": 2, "s": "ab", "a": ["q"], "e": "x", "o": "z"], s).isEmpty)
        let bad = SpecValidator.problems(["n": 4, "s": "abcde", "a": ["q", "r", "t"], "e": "z", "extra": 1, "o": true] as [String: Any], s)
        for needle in ["$.n: > maximum 3", "$.s: longer than 4", "$.a: more than 2 items", "$.e: not one of", "$.extra: not allowed",
                       "$.o: matches 0 oneOf"] {
            #expect(bad.contains { $0.hasPrefix(needle) }, "\(needle) in \(bad)")
        }
        #expect(SpecValidator.problems([String: Any](), s) == ["$.n: required"])
        #expect(SpecValidator.problems(["n": 1.5], s).contains("$.n: not integer"))
        #expect(SpecValidator.problems(json: "{", schemaJSON: "{}") == ["$: not valid JSON"])
    }

    @Test func createDocumentSchemaAndSemantics() {
        let known: (String) -> Bool = { $0 == "att1" }
        let ok = ##"{"format":"pdf","title":"T","markdown":"# Hi\n\n![a](att1)","images":[{"ref":"att1"}]}"##
        #expect(CreateDocumentTool.problems(argumentsJSON: ok, imageExists: known).isEmpty)
        #expect(CreateDocumentTool.problems(argumentsJSON: #"{"format":"rtf","title":"T","markdown":"x"}"#, imageExists: known)
            .contains { $0.hasPrefix("$.format: not one of") })
        #expect(CreateDocumentTool.problems(argumentsJSON: #"{"format":"pdf","markdown":"x"}"#, imageExists: known) == ["$.title: required"])
        #expect(CreateDocumentTool.problems(argumentsJSON: #"{"format":"pdf","title":"T","markdown":"   "}"#, imageExists: known) == ["$.markdown: empty"])
        let unknown = CreateDocumentTool.problems(argumentsJSON: #"{"format":"docx","title":"T","markdown":"![x](nope)","images":[{"ref":"gone"}]}"#,
                                                  imageExists: known)
        #expect(unknown.contains { $0.contains("\"gone\"") } && unknown.contains { $0.contains("\"nope\" is not in `images`") })
        let remote = CreateDocumentTool.problems(argumentsJSON: #"{"format":"pdf","title":"T","markdown":"![x](https://example.org/a.png)"}"#,
                                                 imageExists: known)
        #expect(remote.contains { $0.contains("web address") })
        let repair = CreateDocumentTool.repairText(["$.title: required"])
        #expect(repair == #"{"errors":["$.title: required"],"repair":true}"#)
    }

    @Test func filenames() {
        #expect(CreateDocumentSpec(format: .pdf, title: "Q3: Report/Final", markdown: "x").filename == "Q3- Report-Final.pdf")
        #expect(CreateDocumentSpec(format: .md, title: "..notes.md", markdown: "x").filename == "notes.md")
        #expect(CreateDocumentSpec(format: .docx, title: "  ", markdown: "x").filename == "Untitled.docx")
        #expect(CreateDocumentSpec.defaultPageSize(locale: Locale(identifier: "en_US")) == .letter)
        #expect(CreateDocumentSpec.defaultPageSize(locale: Locale(identifier: "nl_NL")) == .a4)
    }

    @MainActor
    @Test func runSavesAnArtifactVersion() async throws {
        let db = try AppDatabase.inMemory()
        let chat = try ChatRepository(db).create(title: "files")
        let root = try FileOutFixtures.scratch()
        let store = ArtifactStore(database: db, mediaRoot: root, incognito: false)
        let args = ##"{"format":"md","title":"Notes","markdown":"# Notes\n\n- one"}"##
        let text = try await CreateDocumentTool.run(argumentsJSON: args, chatID: chat.id, messageID: "no-such-message", store: store)
        let r = try #require(CreateDocumentTool.result(ofText: text))
        #expect(r.file == "Notes.md" && r.format == "md" && r.version == 1 && r.pages == nil)
        #expect(try String(contentsOfFile: r.path, encoding: .utf8) == "# Notes\n\n- one\n")
        #expect(r.path.hasPrefix(root.path) && r.path.contains("/\(Calendar(identifier: .gregorian).component(.year, from: Date()))/"))
        let (artifact, version, blob) = try db.read { d in
            (try ArtifactRecord.fetchOne(d, key: r.artifact_id), try ArtifactVersionRecord.filter(Column("artifact_id") == r.artifact_id).fetchOne(d),
             try FileBlobRecord.fetchOne(d, sql: "SELECT * FROM file_blob"))
        }
        #expect(artifact?.kind == "md" && artifact?.title == "Notes.md" && artifact?.chatID == chat.id)
        #expect(version?.n == 1 && version?.parentVersionID == nil && version?.specJSON == args && version?.createdByMessageID == nil)
        #expect(blob?.origin == .generated && blob?.size == 15)
        // A revision of the same artifact is version 2 with its parent (T10's versions use this path).
        let v2 = try store.save(chatID: chat.id, kind: "md", filename: "Notes.md", data: Data("# Notes v2\n".utf8), specJSON: nil,
                                messageID: nil, revises: r.artifact_id)
        #expect(v2.version == 2 && v2.artifactID == r.artifact_id)
        let parent = try db.read { d in try ArtifactVersionRecord.fetchOne(d, key: v2.versionID)?.parentVersionID }
        #expect(parent == version?.id)
        // Image refs resolve through attachment / artifact ids.
        #expect(store.imageData(ref: r.artifact_id, chatID: chat.id) == Data("# Notes v2\n".utf8))
        #expect(store.imageData(ref: "missing", chatID: chat.id) == nil)
    }

    @Test func incognitoStoreWritesToATempDir() throws {
        let store = ArtifactStore.forDatabase(try AppDatabase.inMemory())
        #expect(store.incognito && store.mediaRoot.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(store.mediaRoot.lastPathComponent.hasPrefix("AntiChat-incognito-out-"))
    }
}
