#!/usr/bin/env python3
# M2.T23 step 5 (R-235 AC4 = R-030 AC1 targets): precision / recall of the FULL STACK (pre-router + chat model +
# fallback re-ask) on the 200-prompt held-out set, from `antichat-bench router --stack --set test --json <in>`.
# Outcome per prompt = the tool the turn actually called (create_image → image, create_video → video, web_search,
# create_file, memory_write; none → chat). Bar: image intent (image_create ∪ image_edit) and video intent
# (video_create ∪ video_from_image) precision ≥ 0.95 and recall ≥ 0.90.
#   python3 -I tools/router/accuracy.py <stack.json> --out build/at/AT-235/accuracy-<T>.json
import json, sys

TOOL = {"create_image": "image", "create_video": "video", "web_search": "web_needed", "create_file": "file_output",
        "memory_write": "memory_write"}
GROUP = {"image_create": "image", "image_edit": "image", "video_create": "video", "video_from_image": "video",
         "web_needed": "web_needed", "file_output": "file_output", "memory_write": "memory_write", "chat": "chat"}
CLASSES = ["image", "video", "web_needed", "file_output", "memory_write", "chat"]


def outcome(called):
    for t in ("create_video", "create_image", "web_search", "create_file", "memory_write"):
        if t in called:
            return TOOL[t]
    return "chat"


def main():
    d = json.load(open(sys.argv[1]))
    turns = d["turns"]
    conf = {a: {b: 0 for b in CLASSES} for a in CLASSES}
    for t in turns:
        conf[GROUP[t["label"]]][outcome(t["called"])] += 1
    per = {}
    for c in CLASSES:
        if c == "chat":
            continue
        # a class's "called" counts any turn that called its tool, even next to another tool
        tool = {v: k for k, v in TOOL.items()}[c]
        tp = sum(1 for t in turns if GROUP[t["label"]] == c and tool in t["called"])
        fp = sum(1 for t in turns if GROUP[t["label"]] != c and tool in t["called"])
        fn = sum(1 for t in turns if GROUP[t["label"]] == c and tool not in t["called"])
        p = tp / (tp + fp) if tp + fp else 1.0
        r = tp / (tp + fn) if tp + fn else 0.0
        per[c] = {"precision": round(p, 3), "recall": round(r, 3), "tp": tp, "fp": fp, "fn": fn}
    bar = {c: per[c]["precision"] >= 0.95 and per[c]["recall"] >= 0.90 for c in ("image", "video")}
    out = {"model": d.get("model"), "cap": d.get("cap"), "set": d.get("set"), "n": len(turns),
           "reasks": sum(t["reasks"] for t in turns), "offers": sum(1 for t in turns if t["offer"]),
           "errors": sum(1 for t in turns if t.get("error")), "per_class": per, "confusion": conf,
           "bar": {"precision": 0.95, "recall": 0.90}, "pass": bar, "PASS": all(bar.values()),
           "prototypes_sha256": d.get("prototypes_sha256")}
    if "--out" in sys.argv:
        json.dump(out, open(sys.argv[sys.argv.index("--out") + 1], "w"), indent=1)
    print(json.dumps({k: out[k] for k in ("cap", "n", "reasks", "offers", "errors", "per_class", "pass")}, indent=1))


if __name__ == "__main__":
    main()
