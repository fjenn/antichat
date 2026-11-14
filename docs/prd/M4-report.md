# M4 report: ChildSafetyCheck, media job runner, Photo (2026-11-08, branch m4/photo)

Status: see the STATUS line at the end (2026-11-09: M4 done; Photo ships).

## ATs (by ID)
| AT | Result | Evidence |
|---|---|---|
| AT-285 (full set, forced verdicts + runner legs) | pass, 9 tests in 3 suites + runner suites | build/at/AT-285/2026-11-08-runner.log |
| r241-audit (rules 0–5, rule 2 receiver-independent, README, nm scan) | pass, `make audit` EXIT=0 | gate run |
| AT-286 / AT-NFR-M3 (handoff T1) | pass: unload 0.06–0.13 s, peak 6.1 GB ≤ 9.5 | build/at/AT-286/handoff-T1.json |
| AT-030 AC1 (intent, real create_image) | pass: image P 0.981 R 0.981; video P 1.000 R 0.970 | build/at/AT-030/intent.json |
| AT-235 AC4 (stack) | pass: image P 0.981 R 1.000; video P 1.000 R 0.970 | build/at/AT-235/m4/accuracy-T1.json |
| AT-287 (provenance) | AC1/AC3/AC4 pass; AC2 unit leg pass, XCUITest pending (Q-015) | build/at/AT-287/ |
| AT-032 (result card, viewer) | in-process legs pass; XCUITest pending (Q-015); variant strip pending with M11 variants | build/at/AT-032/ |
| AT-033 (edit by text) | ImageEditFlow pass; EditGolden 5/5 (klein img2img T1; img-edit T3); Qwen vision launch check pass; masked edits now composited onto the source through a feathered mask (round 2; real-model re-run with the outside-mask bar: see Open); XCUITest pending | build/at/AT-033/ |
| Journey 5 (scripted, in-app) | pass: create → done card → viewer → edit → version 2 → Erase (LaMa) → version 3 → Remove background (noSubject on the scripted gradient); safety-missing card; install card; real gate with the dev detectors | build/at/AT-VQ-M4/ |
| AT-VQ-M4 captures | 18 shots 1440×900 light + dark (tools/visual/vq-05-image.{sh,md}); blocked tile only in the UI-testing configuration (snapshot + at-285 cover it); blind scoring → M9.T08 | build/at/AT-VQ-M4/ |
| Offline journeys | journey 5 under deny-outbound: 0 denies, 0 IP sockets; offline-only idle 0/0; journeys 2/4/8/11 XCUITest-only (Q-015) | build/at/M4-offline/ |
| AT-034 (Erase, Remove background) | MaskCompositor/MaskFidelity 5/5 at 0/255 outside the mask; RemoveBackground IoU 0.971–0.999; XCUITest pending | build/at/AT-034/ |
| AT-031, AT-291, AT-236, AT-NFR-F1/F2/F6 | as committed at their tasks (M4.T04–T08, T02) | build/at/ |

## Headline numbers (T1 cap, gpu-run.sh timing, load avg noted in each file)
- **P1 (final image):** submit→final 25.5–26.6 s + final check 1.37–1.46 s, at load 14–17. Before this work the check alone took 31.5 s. Detector load: 27–31 s → 1.0–1.2 s, via compiled-cache compaction (bit-identical verdicts and scores). Files: build/at/AT-NFR-F7/{load-compacted,verdict-identity,t1-final-check,t1-generation-remeasure}.json.
- **P2:** no live previews at T0–T2 (lead decision (a)); T3+ figures are in M9.T05.
- **P4 (edit ≤ 1.5 × create):** 0.95× at T1 and 0.94× at the T3 default (klein img2img); img-edit as "best quality" is 2.11×. File: build/at/AT-NFR-P4/.
- **P5 (remove background):** 0.333 s. ERASE_1024: 1.21 s, raw, not scaled to S1. Files: build/at/AT-NFR-P5/, AT-034/.
- **M3 handoff:** chat unload ≤ 0.13 s; next-turn reload 1.45–2.57 s.

## ChildSafetyCheck
- Single call site, unchanged: only MediaOutputGate imports it, and only MediaJobRunner calls the gate. The review answered "no gate bypass" and gave file:line evidence.
- Inference is serial: one process-wide lane plus a model-run lock. Each check has an overall deadline counted from when it is queued. Diagnosis: scores are reproducible; the only run-to-run differences were deadline fail-closes under host load, so load can add blocks but never remove one.

## Amendments and decisions
- A-M4-T15a (proposed): MaskCompositor lives in Engines (the composite must be gated); `img-erase-fb` is not wired (fallback = sd-server inpaint); background-removal ground truth uses composites.
- Catalog v9: img-erase added to all photo packs, signed with test key A. **Production re-signing needs the owner's M10 key.**
- Migration v30_photo_lineage. Fixtures f59cb48 are on the bare repo's branch m4/photo; push to main after merge.

## Fixed in round 2 (M4.T16)
- Masked edits: composited onto the source through an 8-px-dilated mask with a 4-px feather before the gate. EditGolden as masked edits: klein T1 5/5 and img-edit T3 5/5, in-mask change 28–77/255, outside the band mean 0.000 / max 0. P4 on the masked path: 1.19× (T1), 1.21× (T3 default).
- In-app image flow: the scripted chat engine had no media transport (no image tools), `-UseScriptedImageEngine` and `-FakePackState photo` were not wired app-side, the starter slot gets no tools (D-023 a), and — a product bug — the image card never attached to its job (`.task` on an empty view), so no picture appeared in the app; a safety-missing job showed nothing (now `SafetyMissingCard` with the repair size).
- S-8 §M4 calibration: close summary (F1/F2/F6/F7 aggregates).

## Independent close review (2026-11-09, docs/prd/reviews/M4-review.md)
3 P1 + 8 P2 findings; this branch (`fix/m4-review`) fixes P1-1…P1-3 and P2-3…P2-8 (P2-1 / P2-2 are the M5 fixer's). One line each is in the review's Resolution lines. Two change behaviour:

**A-M4-R1 (amendment, P1-3): live previews below a detector-valid size are never shown.**
- Measurement (csc-bench `preview-size`, CPU EP, not a timing; load 6–12): the minor branch of the rule (people → age queries → ages, nudity not involved) on 144 non-sexual, age-labelled LAGENDA scenes (every 12th row; D-017: age only on non-sexual images, never combined with nudity), rescaled so the longer side is N px. Evidence: build/at/M4-review/preview-size.json.

  | Longer side (shorter p50) | minor flagged ≤15 (n=50) | 16–17 (n=19) | usable face found | any person found |
  |---|---|---|---|---|
  | as stored (853) | 1.00 | 1.00 | 0.98 | 1.00 |
  | 512 (343) | 0.98 | 1.00 | 0.79 | 0.99 |
  | 256 (171) | 0.94 | 0.95 | 0.50 | 0.94 |
  | 128 (86) — T3+ `proj` previews | 0.82 | 0.79 | 0.14 | 0.88 |

  At latent-projection size (~128 px for a 1024² job) the age branch misses ~1 in 5 minors and usable faces almost vanish; the F2 bars (≥ 0.99 / ≥ 0.95) already slip at a 343-px shorter side. Nudity recall at small sizes cannot be measured locally (D-019), so it cannot be shown valid either.
- Decision (fail closed, the final-image check unchanged): `ChildSafetyCheck.evaluatePreview` withholds any preview whose shorter side is below `preview_min_side_px` = 512 (thresholds.json v4) without running anything; the job goes on with progress only and its final image is checked as before. A rule block on a preview still stops the job. Effect: T3+ sd-server previews (~96–128 px) are not shown, so the card behaves like T0–T2 (dot matrix + % pill); video step previews (160-px short side, M5) are not shown either — flagged to the lead and M5. Bringing previews back means decoding them at ≥ 512 px (sd.cpp `vae`/`tae` preview); that cost is a timing item for M9.T05.

**P2-7: a preview check that times out or errors withholds that preview only** (one attempt, no 10 s re-check, nothing counted); finals keep the timeout ⇒ re-check ⇒ block rule.

Also: Release `-Bench image` now uses the signed catalog's detector pins and writes only to `~/Library/Caches/AntiChat/xfer/bench` (the Release check therefore needs the catalog detectors installed in its container); the unpinned dev resolver is DEBUG-only (r241-audit rule 2c). Gates on `fix/m4-review`: `make test-unit` EXIT=0 (load 6–14), `make test-integration-stub` EXIT=0 (load 7–22), `make audit` EXIT=0 (load 7–14).

## Open for the M4 close
- Journey 5 with real models at T1 **in the app**: **done (2026-11-09)**. The 0 % stall was not a worktree collision (embedded XPC services are per app process): the capture's fresh dev container had an empty Models folder, create_image returned `unavailable` without queuing a job, and the card kept its "Creating image 0 %" placeholder forever. Fixed in the product: an unavailable/failed call shows the error card with Retry, a call with no queued job shows it after 60 s, and the queue fails a job the helper doesn't start within 60 s (`job.notStarted`). Real run (klein q4 at T1, real gate, LaMa): create → viewer → edit → Erase → Remove background, 14 shots. It also showed a klein text edit dropping the subject (bare instruction as the img2img prompt); fixed (scene + change). Evidence: build/at/AT-VQ-M4/2026-11-08.log (2026-11-09 section), build/visual/m4fix-real2/.
- Journey 5 **in a Release build at this Mac's real tier (T4-128)**: **done (2026-11-09)**. Try-out build 826 (f87e7c947, main with fix/m4-review merged) ran with the real chat model → create_image (img-klein-q8), viewer, edit (klein img2img, and Best quality with img-edit-q8), Erase mode and Remove background. It ran in a scratch home on a relprobe copy, launched with `open -g` and driven by the Accessibility API (tools/visual/vq-05-release.sh + axdrive.swift). The models img-zit-q8 / img-edit-q8 / img-vae-zit came through the app's download path (`antichat-cli models install`). Timings (gpu-run timing): picture 168 s after send, cold; edit 31 s; Remove background 4 s (load 17–26). Best-quality edit 293 s, cold 22 GB load (load 25–26). Five product bugs found there were fixed with tests: the skipped-call card beside the install card; the file path leaked to the model and into its reply; `image:` references showing as an alt line; the edit card attaching to the previous reply's job (the per-reply call id); the edit card overflowing the column. A painted Erase mask is not driven in Release (no synthetic input may be posted); brush + LaMa are covered by the Debug real leg. Evidence: build/at/AT-VQ-M4/2026-11-08.log (Release T4 section), build/at/AT-VQ-M4/release-t4/.
- XCUITest legs: Q-015. Blind scoring of S-11/S-13: M9.T08.
- Moved to M9.T05: T3 repeats, R1/R4/R5/M4 re-runs, quiet-host P1.
- Photo in `ModelPack.shipped`: **done (2026-11-09, branch `fix/closeout`)**. Release builds now ship `[.chat, .voice, .photo, .video]` (`Selection.swift`, `tools/ci/tryout-guard.py`, `ShippedPacksDefaultTests`, `ShippedPacksAndSetupTests`); no pack shows "Coming soon" any more, and the "Coming soon" path stays tested with Photo held back through the `shipped` seam. Settings › Capabilities snapshots re-recorded.

STATUS: M4 done (2026-11-09) — Photo ships (`ModelPack.shipped`); every M4 AT passes in-process or with real models, journey 5 passes in the app at T1 and in a Release build at T4, the independent review's findings are fixed (`4cce6d026`); open: XCUITest legs (Q-015, owner), blind scoring of S-11/S-13 (M9.T08), T3 repeats and R1/R4/R5/M4 re-runs (M9.T05), production catalog re-signing (owner key ceremony, M10).
