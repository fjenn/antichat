#!/usr/bin/env python3
# M2.T23 step 2 (R-235 AC4; P-shell-13): per-route thresholds from a calibration score dump.
# Port of aurelio-labs/semantic-router@aef8310 `semantic_router/routers/base.py` fit()/evaluate() (L145-175: search
# per-route `score_threshold`s that maximise accuracy on labelled utterances; MIT), adapted: thresholds are searched
# per route to maximise F1 under the constraint precision ≥ 0.95 (one-vs-rest by exposed tool, a row is predicted r
# when its r score exceeds its chat score by the threshold: margins separate far better than raw cosines), `high` = the lowest threshold ≥ low with precision 1.0 on the
# calibration rows (the fallback intent check's "confident"). Writes the thresholds + the frozen dataset sha into
# route-prototypes.json.
#   python3 -I tools/router/fit.py <calib-dump.json> --dataset <router-300.jsonl> [--prototypes <route-prototypes.json>]
import hashlib, json, sys

INTENTS = ["image_create", "image_edit", "video_create", "video_from_image", "web_needed", "file_output", "memory_write"]
# Routes that expose the same tool count as one class (image_create ∪ image_edit → create_image; video_* → create_video):
# a confusion inside a group calls the same tool, so it is not a false positive (R-235 AC4 measures the groups).
TOOL = {"image_create": "image", "image_edit": "image", "video_create": "video", "video_from_image": "video",
        "web_needed": "web", "file_output": "file", "memory_write": "memory", "chat": "chat"}
MIN_PRECISION = 0.95


def prf(rows, route, t):
    tp = fp = fn = 0
    for r in rows:
        s = r["scores"]
        pred = s[route] - s["chat"] >= t  # thresholds are on the margin over the chat score
        pos = TOOL[r["label"]] == TOOL[route]
        tp += pred and pos
        fp += pred and not pos
        fn += (not pred) and pos
    p = tp / (tp + fp) if tp + fp else 1.0
    rc = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * p * rc / (p + rc) if p + rc else 0.0
    return p, rc, f1


def fit(rows):
    out, report = {}, {}
    for route in INTENTS:
        cands = sorted({round(r["scores"][route] - r["scores"]["chat"], 4) for r in rows})
        best = None
        for t in cands:
            p, rc, f1 = prf(rows, route, t)
            if p >= MIN_PRECISION and (best is None or f1 > best[1] or (f1 == best[1] and t < best[0])):
                best = (t, f1, p, rc)
        if best is None:  # precision bar unreachable on calib: the strictest candidate
            t = cands[-1]
            best = (t,) + prf(rows, route, t)[::-1][:1] + prf(rows, route, t)[:2]
        low = best[0]
        high = next((t for t in cands if t >= low and prf(rows, route, t)[0] == 1.0 and prf(rows, route, t)[1] > 0), low)
        out[route] = {"low": round(low, 4), "high": round(max(high, low), 4)}
        p, rc, f1 = prf(rows, route, low)
        report[route] = {"low": out[route]["low"], "high": out[route]["high"], "precision": round(p, 3), "recall": round(rc, 3), "f1": round(f1, 3)}
    return out, report


def top(s, th):
    """PreRouter.top: the intent whose margin over chat exceeds its threshold by the most (nil = chat)."""
    best, gap = "chat", None
    for r in INTENTS:
        g = s[r] - s["chat"] - th[r]["low"]
        if g >= 0 and (gap is None or g > gap):
            best, gap = r, g
    return best


def group_metrics(rows, th):
    out = {}
    for g in sorted(set(TOOL.values()) - {"chat"}):
        tp = fp = fn = 0
        for r in rows:
            pred = TOOL[top(r["scores"], th)] == g
            pos = TOOL[r["label"]] == g
            tp += pred and pos
            fp += pred and not pos
            fn += (not pred) and pos
        p = tp / (tp + fp) if tp + fp else 1.0
        rc = tp / (tp + fn) if tp + fn else 0.0
        out[g] = (p, rc, 2 * p * rc / (p + rc) if p + rc else 0.0)
    return out


def objective(rows, th):
    m = group_metrics(rows, th)
    if any(p < MIN_PRECISION for p, _, _ in m.values()):
        return -1.0
    return sum(f for _, _, f in m.values())


def fit_joint(rows, th, rounds=4):
    """Coordinate search over the per-route thresholds of the actual top-1 decision (group F1 sum, every group's
    precision ≥ 0.95), starting from the one-vs-rest fit."""
    th = {r: dict(v) for r, v in th.items()}
    for _ in range(rounds):
        changed = False
        for route in INTENTS:
            cands = sorted({round(r["scores"][route] - r["scores"]["chat"], 4) for r in rows})
            best_t, best = th[route]["low"], objective(rows, th)
            for t in cands:
                th[route]["low"] = t
                v = objective(rows, th)
                if v > best + 1e-9 or (abs(v - best) < 1e-9 and t < best_t):
                    best_t, best = t, v
            changed |= best_t != th[route]["low"]
            th[route]["low"] = best_t
            th[route]["high"] = max(th[route]["high"], best_t)
        if not changed:
            break
    for r in INTENTS:
        th[r]["high"] = th[r]["low"]  # confident = selected by the fitted top-1 rule (precision ≥ 0.95 per group)
    return th


def decisive_gap(rows, th):
    """The smallest gap (excess of the top media intent over the best intent of another tool) above every calibration
    row the top-1 rule sends to the wrong media tool, rounded up to 0.01: a near-tie is never confident."""
    worst = 0.0
    for r in rows:
        s = r["scores"]
        t = top(s, th)
        if t == "chat" or TOOL[t] not in ("image", "video") or TOOL[r["label"]] == TOOL[t]:
            continue
        mine = s[t] - s["chat"] - th[t]["low"]
        other = max(s[x] - s["chat"] - th[x]["low"] for x in INTENTS if TOOL[x] != TOOL[t])
        worst = max(worst, mine - other)
    return round(int(worst * 100 + 1) / 100, 2) if worst > 0 else 0.0


def main():
    dump = json.load(open(sys.argv[1]))
    assert dump.get("set") == "calib", "fit only on the calibration split"
    ds = sys.argv[sys.argv.index("--dataset") + 1]
    protos = sys.argv[sys.argv.index("--prototypes") + 1] if "--prototypes" in sys.argv else \
        "Packages/Harness/Resources/router/route-prototypes.json"
    sha = hashlib.sha256(open(ds, "rb").read()).hexdigest()
    th, report = fit(dump["rows"])
    th = fit_joint(dump["rows"], th)
    report = {"per_route_one_vs_rest": report, "thresholds": th,
              "calib_groups": {g: {"precision": round(p, 3), "recall": round(rc, 3)} for g, (p, rc, _) in group_metrics(dump["rows"], th).items()}}
    p = json.load(open(protos, encoding="utf-8"))
    p["thresholds"] = th
    p["decisiveGap"] = decisive_gap(dump["rows"], th)
    report["decisiveGap"] = p["decisiveGap"]
    p["datasetSHA256"] = sha
    with open(protos, "w", encoding="utf-8") as f:
        json.dump(p, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(json.dumps({"dataset_sha256": sha, "calib_rows": len(dump["rows"]), "routes": report}, indent=1))


if __name__ == "__main__":
    main()
