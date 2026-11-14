#!/usr/bin/env python3
"""AT-231 gate over build/at/AT-231/tools.json (written by `make test-integration-real TIER=T1 FILTER=ToolEval` or
`antichat-bench tools`): constrained_rate == 1, parse_valid_rate >= 0.98, schema_valid_rate >= 0.98,
correct_tool_rate >= 0.90, raw_syntax_leaks == 0, 200 rows. Prints each check; exit 1 on any miss."""
import json
import sys
from pathlib import Path

p = Path(sys.argv[1] if len(sys.argv) > 1 else "build/at/AT-231/tools.json")
d = json.loads(p.read_text(encoding="utf-8"))
m = d["metrics"]
checks = [
    ("rows == 200", d.get("rows") == 200, d.get("rows")),
    ("constrained_rate == 1 (trace flag constrained=true on every call)", m["constrained_rate"] == 1, m["constrained_rate"]),
    ("parse_valid_rate >= 0.98", m["parse_valid_rate"] >= 0.98, m["parse_valid_rate"]),
    ("schema_valid_rate >= 0.98", m["schema_valid_rate"] >= 0.98, m["schema_valid_rate"]),
    ("correct_tool_rate >= 0.90", m["correct_tool_rate"] >= 0.90, m["correct_tool_rate"]),
    ("raw_syntax_leaks == 0", m["raw_syntax_leaks"] == 0, m["raw_syntax_leaks"]),
]
for name, ok, v in checks:
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {v}")
print("counts:", json.dumps(d.get("counts"), sort_keys=True))
print("grammar_overhead:", json.dumps(d.get("grammar_overhead"), sort_keys=True))
sys.exit(0 if all(ok for _, ok, _ in checks) else 1)
