# Translation pass (M9.T04 step 2)

How AntiChat's UI strings are translated into de, fr, es, nl and pt (Brazilian Portuguese, shipped as `pt`).
English lives in `docs/research/10-architecture/design-system/copy-deck.md` and stays the only source of truth.
Translations live next to it in `translations/<lang>.json`; `tools/design/gen-xcstrings.py` merges them into
`App/AntiChat/Localizable.xcstrings` (never edit the catalog by hand).

## Roles
1. **Translator** (one agent per language): translates every key, writes batches with `l10n.py set`.
2. **Reviewer** (a different agent per language, never the translator): reads every string against the English,
   the copy-deck row and this file, fixes what is wrong through `l10n.py set`, and records what it changed in its
   report. A language ships only after its reviewer signs off.

A-M9-T04a records that both roles are Claude agents rather than the local `chat-122b` pass named in M9.md: no
cloud translation API is used, the method (translator + independent reviewer) is unchanged.

## Commands (repo root, `python3 -I`)
- `tools/l10n/l10n.py todo <lang> [--section 5]` — keys still to translate (missing or stale), with the copy-deck
  row for context and the plural categories when the key is a count string.
- `tools/l10n/l10n.py set <lang> batch.json` — merge `{key: "text"}` or, for plural keys,
  `{key: {"one": "…", "other": "…"}}` (fr/es/pt also `"many"`). The whole batch is rejected on any problem.
- `tools/l10n/l10n.py dump <lang> [--section 5]` — English next to the current translation (review).
- `tools/l10n/l10n-check.py --langs de,fr,es,nl,pt --require translated` — the AT-102 gate.
- `python3 -I tools/design/gen-xcstrings.py` — regenerate the catalog after a pass.

## Rules
- **Voice (copy-deck "Voice"):** calm, short, concrete, second person. No exclamation marks in errors. Say what
  happened, then what to do. Never blame the user. No lectures, no added warnings, no softening of Evil Mode copy.
- **Form of address:** de "du" (lower case), fr "vous", es "tú", nl "je/jij", pt-BR "você". Be consistent.
- **Glossary:** `tools/l10n/glossary.csv` terms are fixed. "AntiChat", "Evil Mode", "Evil" and "Mac" are never
  translated. If a term is missing, choose one rendering and keep it everywhere.
- **macOS conventions:** follow Apple's own wording in that language for standard commands (Cut, Copy, Paste,
  Select All, Settings, Close, Minimize, Quit, Show/Hide). Menu items keep their trailing "…" when English has one.
  Menu and button titles use the language's macOS capitalisation (German nouns capitalised; pt-BR menu-bar items in
  title case like Apple's, e.g. "Selecionar Tudo"; fr/es/nl and all other pt strings sentence
  case).
- **Placeholders:** every `{name}` stays exactly as written (same names, same braces, never translated). Their
  order may change. Symbols `⌘ ⌥ ⇧ ⌃ ↩ ·` and `~` stay. Units: French writes `Go` for GB; German writes `Min.`.
- **Length:** UI space is tight. Aim for at most ~130% of the English length on buttons, chips, menu items and
  labels. Prefer a shorter natural phrasing over a literal one. Never abbreviate to the point of being unclear.
- **Plurals:** a plural key gives every CLDR category of the language (de/nl: one, other; fr/es/pt: one, many,
  other). `many` is used for large round numbers in fr/es/pt ("1 000 000 de pages"); write it in that form.
  The `one` form may drop `{count}` when the language naturally does ("the last turn").
- **Verbatim VISION lines** (onboarding `onb.*`) are translated faithfully and kept just as short and punchy.
- **Do not translate:** keyboard shortcut glyphs, file extensions, `RESET` (the user types it), product names of
  third parties (Hugging Face, Composio, Gmail, Google Drive, Slack, GitHub, Notion, Office, Word, Excel,
  PowerPoint, Pages, Keynote, Safari, Finder, Spotlight, VoiceOver), model names.
  If a string asks the user to type a word (e.g. RESET), keep that word in English in the translation.
- Strings that are identical in the target language (e.g. "OK", "AntiChat") are still written, as translated.
