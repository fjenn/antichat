# vq-04-search: AT-VQ-M7 visual QA (M7.T16)

Screens S-10 (web answer, citation pills, Sources panel), S-21 §7 Tools & Connections (Tools page, Web search rows,
Connections + Composio) and §8 Skills, S-24 (web search / MCP / Composio consent sheets, ApprovalCard and its
untrusted variant), S-25 (Offline chip). XCUITest cannot start on this Mac (Q-015) and computer use is not granted,
so the app drives its own windows (`-SearchProbe <dir>` in a `vq-*` mode, `App/AntiChat/VisualQAM7.swift`) with the
ScriptedEngine (no model, no GPU) and captures every screen at **1440×900, system Light and Dark**.

## Run

```
make build
ANTICHAT_FIXTURES=$PWD/fixtures tools/visual/vq-m7.sh            # LEGS="vq-chat vq-settings vq-j12 vq-inject"
```

Output: `build/visual/<version>/vq-m7/<leg>/{probe.json,*-light.png,*-dark.png}` and
`build/visual/<version>/vq-m7/hard-checks.json`. Visual-QA capture is the one exception to the no-focus-steal rule:
the runner sets `ANTICHAT_BACKGROUND=0` so the windows are shown (a dev-container launch is otherwise concealed and
captures blank frames) and the app is activated so sheets are drawn.

## Legs → runbook steps (M7.md M7.T16 step 1)

| Leg | Script | Steps | Captures |
|---|---|---|---|
| `vq-chat` | `web-search.jsonl`, `-ScriptedWebSearch YES` | 2–6, 8, 9 | `s10-chip-on`, `s10-answer-pills`, `s10-sources-panel`, `s24-consent-websearch`, `s25-offline-chip` |
| `vq-settings` | `web-plain.jsonl`, `-ScriptedMCP` | 11, vq-10 §7–§8 | `s21-tools-page`, `s21-search-subpage`, `s21-connections-composio`, `s21-connections-add-sheet`, `s24-consent-mcp`, `s21-connections-added`, `s21-skills` (Composio consent not pressed: Debug starts the real relay sign-up) |
| `vq-j12` | `mcp-send-message.jsonl`, `-ScriptedMCP` | 12, journey 12 | `s24-approval-card`, `j12-after-always`, `j12-used-team-chat` |
| `vq-inject` | `web-inject.jsonl`, `-ScriptedWebSearch YES`, `-ScriptedMCP` | 13 | `s24-approval-untrusted` |

Not captured here: the hover card (synthetic mouse-moved events do not drive SwiftUI `.onHover` in-process,
A-M7-T03a d; covered by unit tests and the pending XCUITest), the onboarding step-4 switch (vq-m2 onboarding leg),
the fresh-information hint (AT-228 probe captures), the SkillInstallCard (AT-264 real-leg captures).

## Checks recorded in `probe.json`

- **Zero citation pills without a fetched source** (hard check): `pillsWithoutFetchedSource == []`, and the Sources
  panel rows equal the fetched sources.
- **Pill line break** (A-M7-T03a d): a pill must not push the rest of its paragraph onto a new line. MarkdownView lays
  a paragraph with an embedded view out as a flow of whole runs, so pills go to the end of their line
  (`CitationPill.pillsAtLineEnd`; `PillLineBreakTests`); confirm on `s10-answer-pills-*.png` (`pillFrames`, `pillRows`).
- **Journey 12**: Deny → not sent; Allow once → sent, and the next call asks again; Always allow → sent; the next call
  runs with no card.

## Automated hard checks (`tools/visual/hard-checks.swift`, parity-rubric §2)

H3 contrast (OCR text boxes, WCAG ratio), H5 copy (OCR lines found in the string catalog), H6 grid (long edges on the
4-pt grid), H7 sizes (no "0.0 GB"). H4 (`performAccessibilityAudit`) needs XCUITest: pending (Q-015); the in-process
AT-223 label inventory (`tools/at/at-223-probe.sh`) is the stand-in. Blind S-10/S-21/S-24 scoring is M9.T08.
