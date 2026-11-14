# ChildSafetyCheck

The **only** content check in AntiChat (D-005, D-006, R-241, R-285). Fully local: it reads image pixels in
memory, returns allow or block, and sends nothing anywhere.

## What it does
It blocks sexual content involving minors in **Photo and Video outputs** (generated images, every live
preview, and sampled video frames). Nothing else, in any mode: Normal and Evil behave the same. On a block
the caller discards the output unsaved and shows a neutral "withheld" tile; no reason, score or detail
leaves this package (`Verdict` is `.allow` or `.block`).

## The single category it blocks
"sexual content involving minors": an output that is sexual **and** appears to show a person under 18.
Adult content is never blocked. Non-sexual images of anyone are never blocked.

## Where it is called
Exactly one place: `Packages/Engines/Sources/AntiChatEngines/Media/MediaOutputGate.swift`, from
`MediaJobRunner.emitPreview/emitResult` inside the engine helper, before anything is written to disk or
shown. No other file may import this package; `tools/ci/r241-audit.py` enforces it. The only other importer
is this package's own `csc-bench` tool (calibration and latency, never shipped).

## What it never checks
Text, prompts, chat messages or replies, audio, voice, tool calls, search results, uploaded or input images
(including the source image of an edit), files, and any category other than the one above.

## Models
Off-the-shelf catalog entries, pinned by commit and sha256, ungated, used exactly as published. None is
trained or maintained by AntiChat (D-006, D-007).

| Role | Catalog key | File | Pin | Licence |
|---|---|---|---|---|
| Nudity (primary) | `csc-nudity` | `onnx/model.onnx` (fp32, A-M0-T08a) | `sitatech/freepik_nsfw_detector_onnx@250a86051c7302bc6943ea35b9d778765ca13452` | MIT |
| Age | `csc-age` | `mivolo_v2_age.onnx` | `Sam-Apostel/mivolo-v2-age-onnx@8eb4cd8f5dd4bd28df2c9a43b24bc54d6d139d36` | Apache-2.0 |
| Age bins (body-only second signal, only adds blocks) | `csc-age-bins` | `model.safetensors` (fp32, sha256 `7e0205ae…f90a`) | `prithivMLmods/Age-Classification-SigLIP2@b41e62c0f7b338910c3139c76c183f8dba8a8aca` | Apache-2.0 |
| Nudity (second signal, optional, only adds blocks) | `csc-nudity2` | `marqo-nsfw-384.onnx` | `ICIJ/nsfw-image-detection-384-onnx@4f63fac119fb24a9d98393e57549b1427530ca52` | Apache-2.0 |
| Faces, bodies | — | Apple Vision (system) | `VNDetectFaceRectanglesRequest`, `VNDetectHumanRectanglesRequest` | system |

Runtime: ONNX Runtime 1.24.2 (`microsoft/onnxruntime-swift-package-manager` @ `b7fb7f7`) with the CoreML
execution provider, through the small C shim in `Sources/CSCOrt` (the C API pins the models' symbolic input
dimensions to the fixed sizes we feed; the CoreML EP rejects unbounded dimensions). The age-bin pin publishes
no ONNX file and D-007 rules out publishing a conversion, so `AgeBins.swift` runs its SigLIP base/16 vision
tower directly from the pinned safetensors with Apple Accelerate (BLAS); on identical input tensors it matches
the `transformers` reference to ≤ 1e-4 per bin (S-8 report, M4 calibration).

How it decides (model-matrix §10.3; values in `Sources/ChildSafetyCheck/Resources/thresholds.json`, versioned):

```
nude  = Freepik P(medium) + P(high) ≥ T_n   or   Marqo P(NSFW) ≥ T_n2 (when installed and enabled)
faces = Apple Vision faces (confidence ≥ 0.5, side ≥ 24 px); bodies = Apple Vision human rectangles
age   = MiVOLO v2 (face crop + matched body crop; black when absent)
minor = any face age < 18 + m_face
     or any body without a usable face: body-only age < 18 + m_body
                                         or age-bin P(Child 0–12) + P(Teen 13–20) ≥ T_age_bins
BLOCK iff nude and minor            (not nude ⇒ allow at once; no face or age work runs)
```

The age bins are consulted only for bodies without a usable face, where MiVOLO's body-only estimate is too
loose to meet NFR-F2 by itself; like every second signal they can only add blocks. There is no "nude and no
face ⇒ minor" rule: a nude image in which no person is detected, or whose people are all judged adult by
every signal, is allowed.

Face↔body matching: a body is a candidate for a face when ≥ 60% of the face box lies inside it; among
candidates the highest IoU (tightest body) wins, one-to-one. Video: every frame at a step of
`max(1, floor(fps / 2))` (≥ 2 checked frames per second), plus the first and last frame, plus every preview;
the first blocked frame blocks the whole video.

## Fails closed
- `ChildSafetyCheck(manifest:)` verifies the sha256 of every detector file first: a missing file throws
  `.modelsMissing`, a wrong hash, unreadable thresholds or a model that fails to load throws `.modelsDamaged`.
  The caller then disables Photo/Video output and offers a repair (`safety.missing`).
- A detector error or the per-image deadline (`timeout_ms`) while the image is nude or its nudity is still
  unknown ⇒ `.block`. A non-finite score ⇒ `.block`.
- One check at a time: every evaluation runs on one process-wide lane, so a verdict never depends on what else is
  being checked (concurrent checks slowed each other into the deadline). Every model run holds its engine's lock:
  ONNX Runtime runs (Freepik, Marqo, MiVOLO) never overlap each other, and age-bin forwards (Accelerate) never
  overlap each other. Inside one evaluation the age bins of the body-only people run beside that image's MiVOLO
  runs (different engines, no shared state: each result is what it would be alone; A-M9-T05-F7, proposed). The age
  stage takes all of an image's queries in one MiVOLO call and all body-only crops in one age-bin call; their
  tensors are prepared in parallel on the CPU, the model runs stay one at a time (the pinned MiVOLO graph is fixed
  at batch 1). Both halves always finish before the check returns; an error in either fails the stage.
  The deadline counts from when a check starts; a timed-out check keeps the lane until it ends.
- Video: a stream error, cancellation, an empty clip, or a stream that ends before every sampled frame was
  checked ⇒ `.block`.
- Live previews (`evaluatePreview`, M4 review P1-3 / P2-7): a preview whose shorter side is below
  `preview_min_side_px` is never shown (`.withhold`; nothing runs, the check is not valid at that size), and a
  timeout or detector error on a preview while it is nude or its nudity is unknown withholds that preview only. A
  rule block on a preview still stops the job. Finals are checked by `evaluate` with the rules above, unchanged.

## No setting
No preference, settings row, launch argument or environment variable turns the check off or changes what it
blocks. The only test seam (a forced verdict for the UI "blocked" state) lives inside `MediaOutputGate.swift`
under the `ANTICHAT_UI_TESTING` compilation condition, which exists only in the UI-testing build
configuration; the audit checks that it is absent from Debug and Release binaries.

## Testing
- `swift test --package-path Packages/ChildSafetyCheck --parallel --disable-keychain`: decision-rule truth
  table, face↔body matching, video sampling, manifest hashing and every fail-closed path, with **stub
  detectors and mocked scores only** (test-strategy §2, D-017). No test uses an image with content; the real
  detector plumbing tests (`CSC_REAL_DETECTORS=1`) run on blank frames.
- Calibration uses **lawful proxies only**, tuned separately and kept off the repository: see `METHOD.md`.
  Never create, collect or use sexual imagery of minors, and never combine nudity with a minor in any fixture.
- Status and numbers: `docs/research/07-spikes/S-8-child-safety.md`.
