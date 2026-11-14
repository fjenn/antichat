# ChildSafetyCheck calibration method

Binding for every calibration run (R-285 AC7, D-006, D-017, D-019).

## Data rule
- Only **lawful proxies**. The nudity detector and the age estimator are calibrated **separately**:
  - Nudity: SFW false-positive sets (people-heavy everyday photos and the reviewed CC0 photos) plus the
    detector vendor's published benchmark numbers. No adult-image dataset is used (D-019, answering Q-012):
    public NSFW sets carry no age verification of the people shown, so none is downloaded.
  - Age: non-sexual photographs of faces and people with known ages from public research benchmarks
    (UTKFace: non-commercial research use; LAGENDA: CC BY 2.0, Open Images photos; model-matrix §10.3). The
    age-bin signal is calibrated on the same LAGENDA person crops, never on any image with nudity.
- The nudity × minor conjunction is tested only with mocked detector scores in unit tests.
- **No sexual imagery of minors is ever created, collected, searched for, downloaded or used, and no fixture,
  prompt or generated image ever combines nudity with a minor.**
- The sets live only on the runner under `~/AntiChatPrivateFixtures/csc/` (`nudity/labels.csv`,
  `age/<set>/ages.csv`), never in git. Runs commit **aggregate metrics only**: no image, file name, path or
  per-image score leaves the runner.

## Procedure
1. Nudity: score the SFW rows with `csc-nudity` (and `csc-nudity2`); sweep `T_n` (0.20–0.60 by 0.01) and
   report the SFW flag rate; recall comes from the vendor's published evaluation (NFR-F1, D-019).
2. Age: run MiVOLO on the age sets; for each margin `m_face` (3–12 y) report the flag rate
   (`age < 18 + m`) per true-age band (≤ 15, 16–17, 18–29, ≥ 30); pick the smallest margin meeting NFR-F2;
   same for `m_body` with body-only crops.
   Body-only fusion (A-M4-T02b): on the LAGENDA person crops (no face crop), score MiVOLO body-only age and the
   SigLIP2 age bins `y = P(Child 0–12) + P(Teen 13–20)`; sweep the joint grid `m_body` 0–20 y × `T_age_bins`
   {off, 0.05…0.95 by 0.05} with `minor = age < 18 + m_body OR y ≥ T_age_bins`. Choose the cell with the lowest
   false flag rate at ≥ 30 y among those meeting both recall bars (≤ 15: ≥ 99%, 16–17: ≥ 95%); the recall bars
   come first, because the check's only job is never to pass the forbidden case. If no cell also meets the
   ≥ 30 bar, record the miss (the body-only path then over-flags adults, only ever in nude outputs).
   Never replace this by "nude + no usable face ⇒ minor".
3. End to end: run the full `evaluate` on the SFW set; the withheld rate must meet NFR-F6 (SFW leg).
4. Latency: content-free; CC0 photos at 1024², p95 per image at the T1 cap (NFR-F7).
5. Changed values go to `Sources/ChildSafetyCheck/Resources/thresholds.json` with `version + 1`; the rule
   itself never changes. Numbers go to `docs/research/07-spikes/S-8-child-safety.md` §"M4 calibration".

Shipped values (`thresholds.json` v3): `T_n 0.35`, `T_n2 off`, `m_face 8`, `m_body 10`, `T_age_bins 0.30`
(numbers: S-8 report §"M4 calibration").

Tools: `csc-bench` (package executable), `tools/csc/calibrate.py` (aggregate tables, stdlib only).

Legal sign-off: pending (K-060), required before M10
