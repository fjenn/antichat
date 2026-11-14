#!/bin/bash
# AT-013 fallback runner (M1.T17; Q-015: XCUITest cannot enable automation mode on this Mac, so ComposerMenusTests is
# committed but not run here). Runs the in-process menus probe (`-MenusProbe`, App/AntiChat/MenusProbe.swift) on
# build/AntiChat.app (Debug) with the ScriptedEngine `basic.jsonl` and `-UseScriptedTools YES`, one launch per
# variant of M1.md AT-013:
#   chat-only/         no fake packs (starter chat-0.8b): leg (1) + list; leg (2) triggers; no tool entries (D-023)
#   photo-off/         -FakeInstalledPacks chat,photo,video -FakeDisabledPacks photo: "Enable in Settings" opens Settings
#   full/              + -FakeWebSearchEnabled YES -FakeConnectionsEnabled YES, -ChatModel chat-9b-q4: Web search and
#                      Connections enabled; legs (2) with the tools and (3) chips (pick, send, ×)
#   relaunch/          same container and options as full/: the removed chip stays removed, the other is back
#   relaunch-starter/  same container, -ChatModel chat-0.8b: no chip shown while the starter is active (D-023)
#   full-starter/      full/'s packs and switches with the starter: no Web search / Connections / tool rows (D-023)
# Output: build/at/AT-013/<variant>/{probe.json,*.png}, build/at/AT-013/probe.json (all variants + legs + pass).
# Usage: tools/at/run.sh AT-013 -- tools/at/at-013-probe.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/build/AntiChat.app/Contents/MacOS/AntiChat"
OUT="$ROOT/build/at/AT-013"
SCRIPT="$ROOT/fixtures/scripts/basic.jsonl"
[ -f "$SCRIPT" ] || SCRIPT="$ROOT/tools/fixtures/scripts/basic.jsonl"  # staging copy (A-M1-T05a)
[ -f "$SCRIPT" ] || { echo "missing basic.jsonl (python3 -I tools/fixtures/gen-scripts.py)"; exit 2; }
[ -x "$BIN" ] || { echo "missing $BIN (run make build)"; exit 2; }
mkdir -p "$OUT"
fail=0
FULL=(-FakeInstalledPacks chat,photo,video -FakeWebSearchEnabled YES -FakeConnectionsEnabled YES)
launch() {  # <variant> <container> <args…>
  local name=$1 box=$2; shift 2
  local dir="$OUT/$name"
  rm -rf "$dir"
  "$BIN" -ApplePersistenceIgnoreState YES -OfflineOnly YES -ANTICHAT_DEV_CONTAINER "$box" -UseScriptedEngine "$SCRIPT" \
    -UseScriptedTools YES -MenusProbe "$dir" "$@" >"$OUT/$name.log" 2>&1
  if [ -f "$dir/probe.json" ]; then rm -f "$OUT/$name.log"; else echo "$name: no probe.json"; tail -20 "$OUT/$name.log"; fail=1; fi
}
fresh() { mktemp -d /tmp/antichat-at013-XXXXXX; }
b1=$(fresh); launch chat-only "$b1"
b2=$(fresh); launch photo-off "$b2" -FakeInstalledPacks chat,photo,video -FakeDisabledPacks photo
b3=$(fresh); launch full "$b3" "${FULL[@]}" -ChatModel chat-9b-q4
launch relaunch "$b3" "${FULL[@]}" -ChatModel chat-9b-q4
launch relaunch-starter "$b3" "${FULL[@]}" -ChatModel chat-0.8b
b4=$(fresh); launch full-starter "$b4" "${FULL[@]}" -ChatModel chat-0.8b
rm -rf "$b1" "$b2" "$b3" "$b4"
python3 -I - "$OUT" <<'PY' || fail=1
import json, os, sys
o = sys.argv[1]
def load(n):
    try:
        return json.load(open(os.path.join(o, n, "probe.json")))
    except Exception as e:  # a missing variant fails its legs
        return {"error": str(e)}
v = {n: load(n) for n in ("chat-only", "photo-off", "full", "relaunch", "relaunch-starter", "full-starter")}
def rows(n):
    return {r["id"]: r for r in v[n].get("leg1", {}).get("rows", [])}
def l2(n):
    return v[n].get("leg2", {})
c, p, f, fs = rows("chat-only"), rows("photo-off"), rows("full"), rows("full-starter")
legs = {
    # (1) chat only: files, image/video disabled "Install {pack} to use this", project; no web/connections
    "1a-chat-only-list": list(c) == ["files", "image", "video", "project"] and c["files"]["enabled"]
        and not c["image"]["enabled"] and c["image"]["reason"] == "Install Photo to use this"
        and not c["video"]["enabled"] and c["video"]["reason"] == "Install Video to use this"
        and all(r["onScreen"] for r in c.values()) and v["chat-only"]["leg1"]["menuOpened"],
    # (1) Photo installed but off: listed, "Enable in Settings", the click opens Settings
    "1b-photo-off-enable-in-settings": "image" in p and not p["image"]["enabled"]
        and p["image"]["reason"] == "Enable in Settings" and p["image"]["onScreen"]
        and v["photo-off"]["leg1"]["settingsOpened"] == 1 and p.get("video", {}).get("enabled") is True,
    # (1) full fake set: Web search and Connections present and enabled
    "1c-full-web-connections": f.get("web", {}).get("enabled") is True and f.get("connections", {}).get("enabled") is True
        and f["web"]["onScreen"] and f["connections"]["onScreen"],
    # (2) / at start and @ mid-text open the same list; typing filters; wrap both ways; / mid-text does not open
    "2-triggers-filter-wrap": all(l2(n).get("slashOpened") and l2(n).get("atOpened") and l2(n).get("sameList")
                                  and l2(n).get("filters") and l2(n).get("wraps") and l2(n).get("escCloses")
                                  and l2(n).get("noMatchesShown") and l2(n).get("slashMidTextOpens") is False
                                  for n in ("chat-only", "full")),
    # (3) picking shows a chip; it stays after the send; × removes it; removed after relaunch
    "3-sticky-chips": (lambda l3, r: l3.get("chipsAfterPick") == ["toolChip.tool:echo", "toolChip.tool:write_note"]
                       and l3.get("textAfterPick") == "" and l3.get("sendReplied")
                       and l3.get("chipsAfterSend") == ["toolChip.tool:echo", "toolChip.tool:write_note"]
                       and l3.get("storedAfterSend") == ["tool:echo", "tool:write_note"]
                       and l3.get("chipsAfterRemove") == ["toolChip.tool:write_note"]
                       and l3.get("storedAfterRemove") == ["tool:write_note"]
                       and r.get("chipsOnScreen") == ["toolChip.tool:write_note"]
                       and r.get("chipsStored") == ["tool:write_note"])(v["full"].get("leg3", {}), v["relaunch"].get("relaunch", {})),
    # D-023: no tool entries or chips while the starter is active
    "d023-starter-no-tools": list(fs) == ["files", "image", "video", "project"]
        and not any(i.startswith("tool:") for i in l2("chat-only").get("slashList", []) + l2("full-starter").get("slashList", []))
        and v["relaunch-starter"].get("relaunch", {}).get("chipsOnScreen") == []
        and v["relaunch-starter"].get("relaunch", {}).get("chipsStored") == ["tool:write_note"],
}
for n, d in v.items():
    print(n, "model", d.get("activeModel"), "phase", d.get("phase"), "error", d.get("error", "-"))
    if "leg1" in d: print("  + rows:", [(r["id"], r["enabled"], r["reason"]) for r in d["leg1"]["rows"]])
    if "leg2" in d: print("  leg2:", {k: d["leg2"][k] for k in ("slashList", "filtered", "upFromFirst", "downFromLast", "wraps", "slashMidTextOpens")})
    if "leg3" in d: print("  leg3:", d["leg3"])
    if "relaunch" in d: print("  relaunch:", d["relaunch"])
ok = all(legs.values())
json.dump({"at": "AT-013", "form": "in-process probe (Q-015 fallback)", "pass": ok, "legs": legs, "variants": v},
          open(os.path.join(o, "probe.json"), "w"), indent=2, sort_keys=True)
print("legs:", legs, "pass:", ok)
sys.exit(0 if ok else 1)
PY
exit $fail
