// M5.T13 (R-022 AC1, G-026; P-files-tools-08): the Library's search index. `library_doc` holds one row per searchable
// stored file — every artifact version (name = the artifact's title, prompt = `spec_json.prompt`) and every attachment
// (name = display_name) — and `library_fts` is an FTS5 external-content index over (name, prompt). Triggers keep both in
// step with artifact_version / artifact / attachment inserts, renames and deletes (FK cascades fire them too), and the
// migration backfills what exists. LibraryIndex lists the rows themselves from the base tables; the index only answers
// "which items match". Incognito chats live in an in-memory database, so nothing of theirs reaches this file.
// Numbered v33: v30 (photo lineage) and v31 (image description, M9.T02) are main's, v32 is M5.T08's; numbers are global (renumbered at the M5 merge; `Migrations.renamed` maps the old v32_library_fts).
import GRDB

extension Migrations {
    /// `spec_json.prompt` of a version row (`''` when the spec is missing or not JSON).
    static func libraryPromptSQL(_ v: String) -> String {
        "COALESCE(CASE WHEN json_valid(\(v).spec_json) THEN json_extract(\(v).spec_json, '$.prompt') END, '')"
    }

    static func v33LibraryFTS(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE library_doc (
              id INTEGER PRIMARY KEY,
              ref_kind TEXT NOT NULL CHECK (ref_kind IN ('version', 'attachment')),
              ref_id TEXT NOT NULL UNIQUE,
              name TEXT NOT NULL DEFAULT '',
              prompt TEXT NOT NULL DEFAULT ''
            );
            CREATE VIRTUAL TABLE library_fts USING fts5(
              name, prompt, content='library_doc', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER library_doc_ai AFTER INSERT ON library_doc
              BEGIN INSERT INTO library_fts(rowid, name, prompt) VALUES (new.id, new.name, new.prompt); END;
            CREATE TRIGGER library_doc_ad AFTER DELETE ON library_doc
              BEGIN INSERT INTO library_fts(library_fts, rowid, name, prompt) VALUES ('delete', old.id, old.name, old.prompt); END;
            CREATE TRIGGER library_doc_au AFTER UPDATE ON library_doc BEGIN
              INSERT INTO library_fts(library_fts, rowid, name, prompt) VALUES ('delete', old.id, old.name, old.prompt);
              INSERT INTO library_fts(rowid, name, prompt) VALUES (new.id, new.name, new.prompt);
            END;
            CREATE TRIGGER library_version_ai AFTER INSERT ON artifact_version BEGIN
              INSERT INTO library_doc(ref_kind, ref_id, name, prompt)
                SELECT 'version', new.id, a.title, \(libraryPromptSQL("new")) FROM artifact a WHERE a.id = new.artifact_id;
            END;
            CREATE TRIGGER library_version_ad AFTER DELETE ON artifact_version
              BEGIN DELETE FROM library_doc WHERE ref_id = old.id; END;
            CREATE TRIGGER library_version_au AFTER UPDATE OF spec_json ON artifact_version
              BEGIN UPDATE library_doc SET prompt = \(libraryPromptSQL("new")) WHERE ref_id = new.id; END;
            CREATE TRIGGER library_artifact_au AFTER UPDATE OF title ON artifact BEGIN
              UPDATE library_doc SET name = new.title WHERE ref_id IN (SELECT id FROM artifact_version WHERE artifact_id = new.id);
            END;
            CREATE TRIGGER library_attachment_ai AFTER INSERT ON attachment
              BEGIN INSERT INTO library_doc(ref_kind, ref_id, name) VALUES ('attachment', new.id, new.display_name); END;
            CREATE TRIGGER library_attachment_ad AFTER DELETE ON attachment
              BEGIN DELETE FROM library_doc WHERE ref_id = old.id; END;
            CREATE TRIGGER library_attachment_au AFTER UPDATE OF display_name ON attachment
              BEGIN UPDATE library_doc SET name = new.display_name WHERE ref_id = new.id; END;
            INSERT INTO library_doc(ref_kind, ref_id, name, prompt)
              SELECT 'version', v.id, a.title, \(libraryPromptSQL("v")) FROM artifact_version v JOIN artifact a ON a.id = v.artifact_id;
            INSERT INTO library_doc(ref_kind, ref_id, name) SELECT 'attachment', id, display_name FROM attachment;
            """)
    }
}
