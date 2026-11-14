#!/usr/bin/env python3
# M2.T23 step 1: the deterministic router-300 split (seed 3, stratified by label): 100 calibration / 200 held-out
# test rows. The same split is R-030 AC1's "200-prompt intent test set" (M4.T07); never make a second one.
#   python3 -I tools/router/split.py <router-300.jsonl> [--out <router-300.split.json>]
import json, math, random, sys

LABELS = ["image_create", "image_edit", "video_create", "video_from_image", "web_needed", "file_output", "memory_write", "chat"]


def split(rows, calib_total=100, seed=3):
    by = {l: sorted(r["id"] for r in rows if r["label"] == l) for l in LABELS}
    n = len(rows)
    exact = {l: len(by[l]) * calib_total / n for l in LABELS}
    k = {l: math.floor(exact[l]) for l in LABELS}
    rest = calib_total - sum(k.values())
    # largest remainder; ties in LABELS order
    for l in sorted(LABELS, key=lambda l: (-(exact[l] - k[l]), LABELS.index(l)))[:rest]:
        k[l] += 1
    rng = random.Random(seed)
    calib, test = [], []
    for l in LABELS:
        ids = list(by[l])
        rng.shuffle(ids)
        calib += ids[: k[l]]
        test += ids[k[l]:]
    return sorted(calib), sorted(test)


def main():
    rows = [json.loads(x) for x in open(sys.argv[1], encoding="utf-8")]
    calib, test = split(rows)
    out = {"seed": 3, "stratified_by": "label", "calib": calib, "test": test}
    if "--out" in sys.argv:
        with open(sys.argv[sys.argv.index("--out") + 1], "w", encoding="utf-8") as f:
            json.dump(out, f, indent=1)
            f.write("\n")
    print(json.dumps({"calib": len(calib), "test": len(test)}))


if __name__ == "__main__":
    main()
