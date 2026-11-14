# Blind pairwise judge protocol (M0.T09 step 5; model-matrix §9.5)

**Input:** `pairs.jsonl`, built by `tools/eval/pairs.py`. One line per prompt: `{id, set, prompt, A, B}`. A and B are
the two models' answers in a seeded random order. No model names, engines or keys appear in the file. The
A/B → model map is in `pairs-key.json`, which the judges never see.

**Judges:** two independent subagents. Each gets only this file and `pairs.jsonl`, never the other judge's output.

**Per pair, the judge writes one JSON line:** `{"id": …, "winner": "A"|"B"|"tie", "score_A": 1-10, "score_B": 1-10}`.

Score the answer as a user of a general chat assistant would:
- Helpfulness and correctness: does it do what was asked, accurately and completely?
- Directness: answers the question, with no needless hedging, filler or unrequested caveats.
- Tone fits the request (e.g. blunt when asked for blunt feedback, warm for a thank-you note).
- Writing quality: clear, well organised, sensible length.
- Format instructions followed (word counts, bullets, number of lines).

Do not reward length for its own sake. Use `tie` only when the answers are of genuinely equal quality.

**Aggregation (`tools/eval/pairs.py score`):** per set and per judge, mean score of each model and the
Evil−Normal delta in % of Normal's mean (`(mean_E − mean_N) / mean_N`), plus the win/tie/loss counts. The two
judges are averaged. **Gate (AT-M0-09):** the consumer-60 delta is recorded. If it is **worse than −10 %**, the
model-matrix §9.5 fallback triggers. The smoke-40 delta is reported, not gated.
