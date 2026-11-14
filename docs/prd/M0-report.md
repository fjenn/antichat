# M0 report — Proof (close-out, M0.T15)

**Date:** 2026-10-30 · **Branch:** `integration/m0` → `main` (fast-forward) · **Host:** MacBook Pro M5 Max 128 GB (S4/T4), macOS 26.6.2.
**Verdict:** **M0 exit: conditional pass (AT-VQ-M0 pending).** All 14 spike gates AT-M0-00…13 pass (AT-M0-08 `pass-partial` with amendments A-M0-T08a/b; AT-M0-10 with the fallback A-M0-T10a). G-067/G-068 closed, 15 spike rows, 17 NFRs annotated, trace-check `--phase 11` OK. AT-VQ-M0 is `pending`: it needs computer use, which needs the user's approval (Q-021). The static H5 copy check passes. M1 may start; AT-VQ-M0 must pass before M1's own visual QA (AT-VQ-M1), which reuses the same screens.

## 1. Gates

| Task | Gate | Result | Artefact | Fallback / amendment |
|---|---|---|---|---|
| M0.T00 Preconditions | AT-M0-00 | pass (10/10) | `build/at/AT-M0-00/result.json` | Q-010 (no sudo), Q-011 |
| M0.T01 Scaffold, pins, bootstrap (S-0) | AT-M0-01 | pass (14/14) | `build/at/AT-M0-01/`, `07-spikes/bootstrap-run.md` | A-M0-01…05 (minor) |
| M0.T02 + T14 Osaurus closure (S-1) | AT-M0-02 | pass (23/23) | `build/at/AT-M0-02/`, `07-spikes/S-1-osaurus-closure.md` | 8 files ported, swift-sdk OAuth; A-M0-06, A-M0-12 |
| M0.T03 Vendor-sync rehearsal (S-1b) | AT-M0-03 | pass (17/17) | `build/at/AT-M0-03/`, `S-1-vendor-sync.md` | A-M0-14 |
| M0.T04 Engines over XPC (S-3, S-4) | AT-M0-04 | pass (32/32) | `build/at/AT-M0-04/`, `S-3-xpc-engine.md`, `S-4-vmlx.md` | A-M0-07…10, A-M0-13 (minor); **A-M0-11 major, proposed**; Q-014, Q-015 |
| M0.T05 Voice round-trip (S-9) | AT-M0-05 | pass (6/6, `[IN-PIPELINE]`) | `build/at/AT-M0-05/`, `S-9-voice-roundtrip.md` | A-M0-T05a; Q-016 |
| M0.T06 sd-server + handoff (S-5) | AT-M0-06 | pass (16/16) | `build/at/AT-M0-06/`, `S-5-sd-server-handoff.md` | A-M0-T06a; A-M0-T06b proposed (M4); Q-017 |
| M0.T07 Video runtime (S-10) | AT-M0-07 | pass (7/7) | `build/at/AT-M0-07/`, `S-10-video-runtime.md` | I2V via TAEHV (A-M0-T07b); A-M0-T07a; **A-M0-T07c major, proposed**; A-M0-T07d; Q-018 |
| M0.T08 ChildSafetyCheck (S-8) | AT-M0-08 | **pass-partial** (9/9 run; F1, F6-adult `[PENDING-PRIVATE]`) | `build/at/AT-M0-08/`, `S-8-child-safety.md` | A-M0-T08a/b; Q-011, Q-012 (D-019) |
| M0.T09 Evil swap (S-11) | AT-M0-09 | pass (7/7) | `build/at/AT-M0-09/`, `S-11-evil-swap.md` | A-M0-T09a; Q-020 |
| M0.T10 First chat (S-12) | AT-M0-10 | pass with fallback (7/7, `[EMULATED]`) | `build/at/AT-M0-10/`, `S-12-first-chat.md` | 8 MB chunks + token-bucket throttle (A-M0-T10a) |
| M0.T11 Export import (S-13) | AT-M0-11 | pass (13/13) | `build/at/AT-M0-11/`, `S-13-import.md` | A-M0-T11a |
| M0.T12 Signing + licences (S-6, S-7) | AT-M0-12 | pass (8/8) | `build/at/AT-M0-12/`, `S-6-signing.md`, `S-7-licences.md` | ad-hoc library-validation exemption (A-M0-T12a), A-M0-T12b; Q-019 |
| M0.T13 D-012 re-run (S-14) | AT-M0-13 | pass, **A confirmed** | `build/at/AT-M0-13/`, `S-14-d012-rerun.md` | none |
| M0.T15 Close-out | AT-VQ-M0 | **pending** (H5 3/3 pass; 0/12 screenshots) | `build/at/AT-VQ-M0/result.json`, runbook `tools/visual/vq-00-m0-proof.md` | Q-021 |
| M0.T15 Close-out | AT-M0-EXIT | **pending** (every check passes except AT-VQ-M0) | `build/at/AT-M0-EXIT/result.json` | — |

ATs passed: **14/16** (AT-M0-00…13); AT-VQ-M0 and AT-M0-EXIT pending on the visual run.

## 2. NFRs measured (smoke, PRD §4 row M0)

Measured on the M5 Max under each tier's memory cap (budget B, M0.md C5) unless labelled. `[SCALED]` = pp512/bandwidth projection to chips we do not have (D-003). Targets unchanged; annotations are in `02-target/nfr.md`.

| NFR | Target (short) | M0 result p50/p95 (tier, label) | Within target? | report.json key |
|---|---|---|---|---|
| C1 | TTFT p50 ≤ 1.5 s T0/T1, ≤ 0.8 s T3 | T1 9b 0.46/0.60 s, T3-48 35b 0.34/0.36 s; [SCALED] S1 M4 9b 6.65 s, S2 M4 Pro 35b 2.70 s, S1 M1 0.8b 1.99 s (A-M0-11) | partial | `m0.C1.T1.chat-9b-q4`, `m0.C1.T3-48.chat-35b-q4` |
| C1b | TTFT p95 ≤ 3 s T1, ≤ 1.5 s T3 | T1 0.60 s, T3-48 0.36 s; [SCALED] M4 9b 8.77 s, M4 Pro 35b 2.90 s (A-M0-11) | partial | `m0.C1b.T1.chat-9b-q4`, `m0.C1b.T3-48.chat-35b-q4` |
| C2 | decode ≥ 15 (T1) / ≥ 30 (T3) tok/s | T1 97.2/98.6, T3-48 137/147; [SCALED] M4 9b 19.0, M4 Pro 35b 60.9 | yes (in-process T2-24 9b-q8 @M4 [SCALED] 11.2 misses; not the XPC default) | `m0.C2.T1.chat-9b-q4`, `m0.C2.T3-48.chat-35b-q4` |
| C4 | prefill ≥ 150 (T1) / ≥ 400 (T3) tok/s | T1 2,040/2,220, T3-48 2,800/2,830; [SCALED] M4 9b 140, M4 Pro 35b 350 (A-M0-11) | partial | `m0.C4.T1.chat-9b-q4`, `m0.C4.T3-48.chat-35b-q4` |
| C7 | Normal↔Evil swap ≤ 9.5 s at T1 | N→E 1.03/1.04 s, E→N 0.51/0.60 s [WARM-CACHE]; [SCALED] M4 ≈ 3.7 s | yes (T3+ "both warm" case not measured) | `m0.C7.T1.normal_to_evil`, `m0.C7.T1.evil_to_normal` |
| V1 | voice round-trip p50 ≤ 1.5 s T1, ≤ 1.0 s T3 | T1 0.66/1.67 s, T3-48 0.63/1.65 s, T0 0.49/1.49 s [IN-PIPELINE] | yes | `m0.V1.T1.chat-9b-q4`, `m0.V1.T3-48.chat-35b-q4` |
| P1 | image ≤ 150/90/45/20 s (S1–S4) | S4 Q4 1024² 14.8/14.9 s; [SCALED] M1 768² 238 s, M4 122 s, M4 Pro 66.8 s, M5 65.9 s (A-M0-T06b) | partial | `m0.P1.S4.img-klein-q4-1024`, `m0.P1.S4.img-klein-q4-768` |
| P2 | first preview ≤ 5/3/2/1 s | S4 1024² 2.78/2.82 s, 768² 1.59/1.66 s; every [SCALED] class misses (A-M0-T06b) | no | `m0.P2.S4.img-klein-q4-1024`, `-768` |
| VID1 | video ≤ 8/8/3.5/1.5 min | S4 720p 37.3/40.1 s [WARM-CACHE]; [SCALED] M1 480p 341 s, M4 Pro 720p 299 s, M5 720p 166 s | yes (VID2 misses, A-M0-T07c) | `m0.VID1.S4.vid-5b-720p`, `m0.VID1.S4.vid-5b-480p` |
| M1 | cold load ≤ 3 s (≤ 6 GB) / ≤ 8 s (≤ 22 GB) | T1 9b 0.45/0.54 s, T3-48 35b 0.64/1.39 s [WARM-CACHE] | yes (warm cache only) | `m0.M1.T1.chat-9b-q4`, `m0.M1.T3-48.chat-35b-q4` |
| M3 | unload ≤ 1 s; reload ≤ M1 | T1 unload 0.033/0.036 s, reload 0.50/0.52 s [WARM-CACHE] | yes | `m0.M3-unload.T1.chat-9b-q4`, `m0.M3-reload.T1.chat-9b-q4` |
| M5 | first chat ≤ 2 min @ 50 Mbps, ≤ 10 min @ 10 Mbps | 105.7/105.8 s and 523.0/523.6 s, chat-0.8b [EMULATED] | yes | `m0.M5.50mbps`, `m0.M5.10mbps` |
| R1 | peak ≤ tier budget B | T1 9b 6.38 GB, T3-48 35b 20.7 GB, T2-24 co-resident 12.0 GB, video 480p 26.5 GB; T3-48 video 720p 39.0 > 36 GB (A-M0-T07d) | partial | `m0.R1.T1.chat-9b-q4`, `m0.R1.T3-48.chat-35b-q4`, `m0.R1.T3-48.video-720p` |
| F1 | NSFW recall ≥ 97% at precision ≥ 90% | not measured [PENDING-PRIVATE] → M4 (Q-012/D-019); SFW flag rate 0.60% (n 1676) only | pending | `m0.F1.csc` |
| F2 | age recall ≥ 99% (≤ 15) / ≥ 95% (16–17); false flag ≤ 5% | UTKFace 99.8/95.8/1.8%, LAGENDA 100/96.9/1.33% (m_face 8); illustrated [PENDING-PRIVATE]; body-only path misses | partial | `m0.F2.csc` |
| F6 | over-block ≤ 3% adult, ≤ 1% SFW | SFW 0.54%; adult leg [PENDING-PRIVATE] → M4 | partial | `m0.F6.csc` |
| F7 | check ≤ 300 ms p95 (T1) | 77/238 ms on M5 Max at the T1 cap; [SCALED] T1 chips ≈ 1.0–1.7 s (S-8 → M4 G-048) | partial | `m0.F7.T1.csc` |

**Summary:** 17 NFRs measured (smoke); **7 within target** (C2, C7, V1, VID1, M1, M3, M5), 8 partial (pass on this Mac, miss or unproven after scaling / pending legs: C1, C1b, C4, P1, R1, F2, F6, F7), 1 miss (P2, scaled and on S4 at 1024²), 1 pending (F1). No target was changed; the misses are carried by the proposed amendments below.

## 3. Risks (registry/risks.json, M0.T15 step 3)

Closed: K-NEW-GAP-1, K-NEW-GAP-2, K-002 (this Mac), K-045, K-010, K-022 (this Mac), K-011, K-020, K-013 (T2/T3), K-016, K-046, K-017.
Accepted and carried (owner milestone re-checks): K-004/K-006/K-008 → M1 (A-M0-11 re-measure), K-005/K-007/K-009 → M2 (AT-222/AT-221), K-042 → M6, K-015 → M4/M5, K-049 → M10 (notarization), K-019/K-036/K-048 → M4, K-031/K-044 → M2.
Not in `risks.json` (engine/architecture notes; disposition here and in `spikes.json`): closed K-NEW-ARCH-2, K-NEW-ARCH-4, K-NEW-C005-2, K-NEW-ARCH-5, K-NEW-MOD-8, K-NEW-ENG-4, K-NEW-ENG-5 (ad-hoc); carried K-NEW-MOD-5 (LFM3 → GGUF), K-NEW-ENG-7 (pin + suite plan, M1), K-NEW-ENG-1 (M4), K-NEW-ENG-9/10 (M3), K-NEW-ARCH-7 (M6).
`trace-check --phase 11`: OK (no risk left `open`).

## 4. Amendments (M0)

All 28 M0 amendment IDs are unique (`PRD-AMENDMENTS.md`). Two schemes coexist by design: `A-M0-NN` (lead-assigned, renumbered at integration where branches clashed: A-M0-12, A-M0-13) and `A-M0-T<task><letter>` (worktree-assigned, collision-free). No ID was reused.

| Class / status | IDs |
|---|---|
| minor, resolved | A-M0-01, 02, 03, 05, 06, 07, 08, 09, 10, 12, 13, 14; A-M0-T05a, T06a, T07a, T08a, T08b, T09a, T10a, T11a, T12a, T12b |
| minor, proposed (owner milestone) | A-M0-04 (M1), A-M0-T06b (M4), A-M0-T07b (M5), A-M0-T07d (M5) |
| **major, proposed (ask, PRD §1.5)** | **A-M0-11** (scaled TTFT of the T1/T3 defaults; decide after the M1 prefix-cache re-measure), **A-M0-T07c** (NFR-VID2 first preview miss; M5) |

## 5. Questions (M0)

Q-010…Q-021 are unique (the duplicate Q-016 from M0.T09 became **Q-020** at integration). Open: Q-020 (non-blocking, Evil smoke-set scope), **Q-021** (computer use for AT-VQ-M0). Resolved at integration: Q-013 (bench prompts now in the fixtures repo; OCR images still generator-only), Q-016, Q-017. Defaults applied: Q-010, Q-014, Q-015, Q-018, Q-019; Q-011/Q-012 answered by D-017/D-019.

## 6. D-012 switch re-run (S-14)

**A confirmed** (D-009/D-012 assemble base stays). The rule is completed by M1.T01 (S-2): switch to F1 only if our shell costs > 2× G-001…G-006 (26 pw).

## 7. Independent code review (M0.md C2, PRD §1.4 rule 5)

See [`../research/07-spikes/review-M0-close.md`](../research/07-spikes/review-M0-close.md) (range `1ac7bd5..integration/m0`, high effort; earlier reviews `review-M0-T01.md`, `review-M0-T02-T14.md`).

61 findings (Swift 32, tooling 15, spike scripts 14): **4 high, all fixed** — two ChildSafetyCheck fail-open paths (NaN score; cancelled video stream returned `.allow`), `EngineClient.connect(timeout:)` that never timed out, and the AT-M0-04 "no TCP listener" check that could pass with no pid inspected (committed artefact still passes). 36 fixed in total, including a stale `Vendor/VENDORED.json` that made `vendor-sync verify` fail at HEAD, a signing step whose entitlements errors were ignored, `verify-signing` accepting ad-hoc in dev mode, and `hf-fetch --offline` trusting a stale cache. 25 low/medium items are logged with their owning milestone; the one to watch is CR-S-27 (video scratch-dir deletion from an XPC path, fix before media code is promoted, M4/M5). Verdict: the C2 promotion set is promotable.

## 8. Open items carried to M1–M5

| Item | Owner | Source |
|---|---|---|
| AT-VQ-M0 visual run (parts A/B/C) | before AT-VQ-M1 (M1) | Q-021, `tools/visual/vq-00-m0-proof.md` |
| A-M0-11 scaled TTFT (T1/T3 defaults) → re-measure with prefix cache, then ask | M1 | S-3 |
| `[WARM-CACHE]` NFR-M1/M3/C7 → true cold-load runs (needs `purge`/P-ADMIN or a reboot protocol) | M2 | S-3, S-5 |
| `[EMULATED]` NFR-M5 → real link (NLC/admin) and the onboarding UI on the clock | M2 | S-12 |
| HF Retry-After/backoff, 8 MB chunks or sub-chunk resume (G-051) | M2 | S-12, K-031 |
| `[PENDING-PRIVATE]` F1, F6-adult, F2-illustrated; T1 F7 latency path | M4 entry | S-8, Q-012 |
| P1/P2 engine comparison (A-M0-T06b), sd-server token/socket UP patch | M4 | S-5 |
| VID2 first preview (A-M0-T07c major), 720p R1 at T3-48 (A-M0-T07d), I2V TAEHV (A-M0-T07b) | M5 | S-10 |
| BlackHole device-path V1, SmartTurn on real turns, Kokoro streaming | M3 (vq-08) | S-9 |
| Real ChatGPT/Claude exports for the import field set | M8 | S-13 |
| Developer ID + notarization | M10 | S-6, Q-003 |
| `fixtures/images/ocr/` committed (needs Pillow for `make-ocr.py`) | M1 | Q-013 |
| Code-review findings logged (not fixed) | per row in the review | §7 |
