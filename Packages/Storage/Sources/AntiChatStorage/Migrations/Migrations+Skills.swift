// M7.T12 (R-082, R-261; G-034; P-files-tools-16): installed Agent Skills. architecture §5.1 `skill`
// (id, name, path, enabled, manifest_json, trust bundled/user/github, script_policy), created here because no earlier
// migration made the table, plus the M7.T12 flags:
//   apply_all     "Apply to every chat" (R-082 AC3, off by default): the body is applied in every chat (else only
//                 when the user picks it with "/" or, from M7.T13, when the selector matches the request)
//   content_hash  SHA-256 of the skill folder (paths + bytes); changes when the files change on disk
//   embedding     name + description embedding for M7.T13's SkillSelector (nil until indexed)
// The files live in `<Application Support>/AntiChat/Skills/<name>/` (`path` = the folder name). Per-chat switches are
// markers in `chat.tools_json` (`skill.on:<name>` / `skill.off:<name>`, chips `skill:<name>`), never a column here.
// Numbered v29 on purpose (v28 is taken by M5/M6 on other branches); renumber at merge if needed.
import GRDB

extension Migrations {
    static func v29SkillFlags(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE skill (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL UNIQUE,
              path TEXT NOT NULL,
              enabled BOOLEAN NOT NULL DEFAULT 1,
              manifest_json TEXT NOT NULL DEFAULT '{}',
              trust TEXT NOT NULL DEFAULT 'user' CHECK (trust IN ('bundled', 'user', 'github')),
              script_policy TEXT NOT NULL DEFAULT 'never' CHECK (script_policy IN ('never', 'ask', 'allow')),
              apply_all BOOLEAN NOT NULL DEFAULT 0,
              content_hash TEXT NOT NULL DEFAULT '',
              embedding BLOB,
              created_at DOUBLE NOT NULL,
              updated_at DOUBLE NOT NULL
            );
            """)
    }

    /// The down step (M7.T12 rollback): drops the table. The skill folders on disk stay (the user's files); the
    /// pre-migration backup `Backups/pre-v29_skill_flags-<ts>.sqlite` (MigrationRunner) is the other way back.
    public static func v29SkillFlagsDown(_ db: Database) throws {
        try db.execute(sql: """
            DROP TABLE skill;
            DELETE FROM grdb_migrations WHERE identifier = 'v29_skill_flags';
            """)
    }
}
