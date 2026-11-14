# AntiChat export format, version 1

Written by `ExportAllWriter` (Settings › Privacy & Data › Export all data…, File › Export All Data…), read back by
`AntiChatImporter` (Settings › Privacy & Data › Import…; detected by `manifest.json`). M8.T07, R-093.

File name: `AntiChat-Export-<yyyy-MM-dd-HHmm>.zip`. JSON entries are deflated; media entries are stored.

| Entry | Content |
|---|---|
| `manifest.json` | `{"format":"antichat-export","version":1,"app_version","schema_version":"<head migration id>","created_at":"<ISO 8601>","counts":{"chats","messages","projects","memories","media"},"includes_media":bool,"includes_settings":bool}` |
| `chats/<chat-id>.json` | `{"chat":{…},"messages":[…],"parts":[…],"attachments":[…],"feedback":[…],"draft":{…}\|null}`. Rows are objects keyed by column name with every column as stored (timestamps are Unix seconds; booleans 0/1). `messages` are in preorder (each parent before its children). `parts` omit their `id` (re-assigned on import). BLOB columns are dropped. |
| `chats-md/<slug>-<id8>.md` | The active path as Markdown: front matter (`title`, `date`, `updated`, `mode`), `# title`, then `## You` / `## AntiChat` sections. Evil chats begin with the line `> Evil mode`. Pictures link to `../media/<sha256>.<ext>` (or show their name when media is not included). |
| `projects/<project-id>/project.json` | `{"project":{…},"instruction":{…}\|null,"files":[…]}` (`linked_folder_bookmark` dropped; linked folders are referenced by `linked_folder_path` only). |
| `projects/<project-id>/instructions.md` | The instructions as text (when not empty). |
| `projects/<project-id>/files/<name>` | The bytes of each copied project file (media on). |
| `memory/memory.json` | `{"topics":[…],"items":[…]}`: every topic, the active items only (no suggestions, no events). |
| `memory/<topic-slug>.md` | One readable list per topic with active items. |
| `settings/defaults.json` | The app's preference keys (`ExportSettings`: no secrets, tokens, bookmarks, consent, relay ids, window state, Apple/NS keys; JSON-safe values only). Keychain items are never exported. |
| `media/<sha256>.<ext>` | The bytes of every blob an attachment points at (media on). |
| `media/blobs.json` | `[{"row":{file_blob row},"entry":"<zip path>"\|null}]` for every blob an attachment or a copied project file points at; `entry` is null when the bytes are not in the zip (media off, or the file was missing). |

Never exported: models, caches, logs, incognito chats (never on disk), `network_activity`, `local_counter`,
`import_record`, `memory_suggestion`, `memory_event`, MCP servers and their Keychain items, recordings, artifacts.

## Import rules

- `version` greater than 1 → refused (`import.newerExport`).
- Blobs first: a blob whose sha256 is already here is reused; otherwise its bytes go to `<Media>/<yyyy>/<sha256>.<ext>`
  (year of `created_at`) and the row keeps its id; a blob without bytes keeps its row (counted as missing media).
- Projects keep their ids; a project id already here is skipped.
- Memory topics match by id, else by (scope, project, name, case-insensitive); items keep their ids and origin and
  get their `chunk(source='memory')` mirror (embedded by the background indexer).
- Each chat is one transaction, same ids; a chat id already here is skipped (`import_record(source='antichat',
  external_key=<chat id>)`). A chat whose project is not here loses its `project_id`.
- Settings are only restored after the user confirms (`import.settings.ask`).

The lossless guarantee is checked by `RoundTripTests` with `tools/ci/db-canon.py --roundtrip` (AT-093).
