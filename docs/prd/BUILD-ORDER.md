# Build order (D-026)

This is the order the lead follows. One agent per chunk (5–8 tasks), in sequence on one branch (D-025). Items moved to M11 (A1–A10, B1, B3, B4, B5) are not in any chunk; B2 was rejected, so M2.T11 stays in chunk 2.

**Order:** M2 → **owner try-out** → M6 (with M4.T10/T11 pulled forward) → M7 → M8 core → M3 → M4 → M5 → M8 rest → M9 → M10.

## Chunks

| # | Chunk | Tasks |
|---|---|---|
| 1 | M2 base | M2.T01, T02, T03, T04, T05, T06 |
| 2 | M2 downloads | M2.T08, T09, T10, T07, T11 |
| 3 | M2 scheduler | M2.T12, T13, T14, T15, T17 |
| 4 | M2 onboarding | M2.T16, T18, T19, T20, T21 |
| 5 | M2 router + close | M2.T22, T23, T24, T25, T26 |
| — | **pause: owner try-out** (Release-config build; chats may not survive until M8.T01) | |
| 6 | Files in | M4.T10, M4.T11, M6.T01, T02, T03, T04 |
| 7 | Files understand/out | M6.T05, T06, T07, T08, T09, T10 |
| 8 | Files out + runtime | M6.T11, T12, T13, T15, T16 |
| 9 | Code sandbox + close | M6.T17, T18, T19, T20, T21 |
| 10 | Search + MCP | M7.T01, T02, T03, T05, T06, T07, T08 |
| 11 | Relay + skills + close | M7.T10, T11, T12, T13, T14, T15, T16 |
| 12 | Memory + projects | M8.T01, T02, T03, T04, T05 |
| 13 | Data + storage | M8.T06, T07, T09, T10, T11 |
| 14 | Voice core | M3.T01, T15, T02, T03, T04, T05, T06 |
| 15 | Voice conversation | M3.T07, T08, T09, T10, T11, T12, T13, T14 |
| 16 | Photo core | M4.T01, T02, T03, T04, T05, T06 |
| 17 | Photo UX + close | M4.T07, T08, T09, T12, T13, T15, T16 |
| 18 | Video engine | M5.T01, T02, T03, T04, T05, T06, T07 |
| 19 | Video UX + close | M5.T08, T09, T10, T11, T12, T13, T14 |
| 20 | Mac integration + close | M8.T08, T12, T13, T14, T16 |
| 21 | Accessibility + l10n + perf | M9.T01, T02, T03, T04, T05 |
| 22 | Soak, parity, sync, exit | M9.T06, T08, T09, T10 |
| 23 | Release build + site | M10.T01, T02, T03, T04, T05, T06 |
| 24 | Release close | M10.T07, T08, T09, T11 (+ T10 when credentials arrive) |

Chunks 10–11 have 7 tasks each because M7 tasks are small. Chunks 22 and 24 have 4 each because M9.T08 and M10.T09 are large. Chunk 20 is short because M8.T14 now holds only the permission matrix.

## Dependency fixes applied in the task files

1. M4.T10 (file cards, Quick Look, drag-out) and M4.T11 (side panel, versions, sandboxed web preview) run first in the M6 chunk (chunk 6). They are image-independent; CC0 photos replace image job results in their tests.
2. The M6 audio transcription leg (AT-020 audio, M4A column of AT-277) closes in M3.T06. Until then M4A uploads get a tile and show transcription as pending.
3. "Show in Library" stays hidden until M5.T13 builds the Library. AT-277 is 56/64 at M6 close and 64/64 in M5.T13.
4. M6.T16 builds the generic `RuntimeInstaller`, `catalog/runtimes.yaml` format and `sign-runtime.sh`; M5.T01 adopts them.
5. The AT-057 (tools during voice) re-run with real tools moves from M7.T16 to M3.T14.
6. M7.T13 creates `ProcessLauncher` and `tools/ci/no-raw-process.py` itself (M7.T09 is in M11).
7. M8 core (T01–T07, T09–T11) comes before voice. M8.T08 (Privacy page, uses the permission service vendored in M3) and M8.T12–T14 (voice and job events) come after. M8.T01 (migrations + backups) early also protects try-out chats.

## Try-out caveat

Debug builds erase the database when the schema changes (`eraseDatabaseOnSchemaChange`). Give the owner a **Release-config build** and say plainly that chats may not survive until M8.T01.

## Verification scope

Each milestone's verification task follows the "Verification scope (D-025)" note at its top. The items slimmed out of M2–M8 are listed in M9.T05 (NFR re-measurement) and M9.T08 (parity scoring).
M2 close (2026-11-04) added to M9.T05: NFR-M5 20-run p50 + 10 Mbps, U3 perf driver, PR1 tcpdump leg, PR1 journey loop, D3 real bytes (all packs).
