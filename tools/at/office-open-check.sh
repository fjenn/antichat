#!/bin/zsh
# M6.T10 AT-273 check 5 (R-273 AC5) / M6.T11 AT-275 1c: open produced files in the real apps and classify each open.
#   tools/at/office-open-check.sh <bundle-id> <file>                 → prints ok | repair | error
#   tools/at/office-open-check.sh --matrix <dir> [--apps <id,…>] --out <json>
# Apps are resolved by bundle id (M6.md §0.1: Numbers com.apple.Numbers | com.apple.iWork.Numbers, Pages, Keynote,
# Preview, TextEdit, Word, Excel, PowerPoint), opened in the background with `open -g -b` (never brought to the front), given 10 s (OPEN_WAIT), then System Events reads
# the app's windows, sheets and dialog texts: a repair / "couldn't be opened" / corrupt / damaged text → `repair`
# (or `error` when no document window opened), a document window named like the file → `ok`. Each open is
# screenshotted (screencapture -x) next to the JSON. The document is closed without saving afterwards; an app this
# script launched is quit, an app that was already running keeps running (only our window closes). Absent app →
# `not run (Q-M6-01)`. Matrix: pdf → Preview; docx → Pages, Word; xlsx/csv → Numbers, Excel; md → TextEdit;
# pptx → Keynote, PowerPoint. DOCX_EXTRA_APPS=com.apple.TextEdit adds TextEdit (AppKit's OOXML reader) to docx.
set -u
WAIT=${OPEN_WAIT:-10}

resolve() {  # bundle id (or the iWork alias) → app path, empty when absent
  local id=$1 apath
  for i in $id ${${id/com.apple./com.apple.iWork.}}; do
    apath=$(mdfind "kMDItemCFBundleIdentifier == '$i'" 2>/dev/null | head -1)
    [[ -n $apath ]] && { echo "$i|$apath"; return; }
  done
}

check_one() {  # <bundle-id> <file> [shot-dir] → "<verdict>\t<detail>"
  local id=$1 file=${2:A} shots=${3:-} r app apath base running texts verdict detail
  # SKIP_APPS="com.apple.Pages=Q-M6-02 …": an installed app that must not be driven (e.g. a first-launch licence screen).
  local skip
  for skip in ${=SKIP_APPS:-}; do
    if [[ ${skip%%=*} == $id ]]; then print -r -- "not run (${skip#*=})"$'\t'"skipped"; return; fi
  done
  r=$(resolve $id)
  if [[ -z $r ]]; then print -r -- $'not run (Q-M6-01)\tapp absent'; return; fi
  app=${r%%|*}; apath=${r#*|}
  base=${file:t:r}
  running=$(osascript -e "application id \"$app\" is running" 2>/dev/null)
  open -g -b $app "$file" 2>/dev/null || { print -r -- $'error\topen failed'; return; }
  sleep $WAIT
  texts=$(osascript 2>&1 <<OSA
tell application "System Events"
  set out to ""
  set ps to (every process whose bundle identifier is "$app")
  if (count of ps) is 0 then return "NOPROC"
  set p to item 1 of ps
  repeat with w in (every window of p)
    set out to out & "WIN:" & (name of w as text) & linefeed
    try
      repeat with s in (every sheet of w)
        repeat with t in (every static text of s)
          set out to out & "SHEET:" & (value of t as text) & linefeed
        end repeat
      end repeat
    end try
    try
      if subrole of w is "AXDialog" or subrole of w is "AXSystemDialog" then
        repeat with t in (every static text of w)
          set out to out & "DIALOG:" & (value of t as text) & linefeed
        end repeat
      end if
    end try
  end repeat
  return out
end tell
OSA
)
  if [[ -n $shots ]]; then mkdir -p $shots; screencapture -x "$shots/${app##*.}-${file:t}.png" 2>/dev/null; fi
  local lower=${(L)texts} wins=${(L)$(print -r -- "$texts" | grep '^WIN:')}
  if [[ $lower == *(repair|"couldn’t be opened"|"couldn't be opened"|"could not be opened"|"can’t be opened"|"can't be opened"|corrupt|damaged|"unreadable content"|"isn’t in a format"|"isn't in a format")* ]]; then
    if [[ $wins == *${(L)base}* ]]; then verdict=repair; else verdict=error; fi
  elif [[ $wins == *${(L)base}* ]]; then
    verdict=ok
  elif [[ $texts == NOPROC* ]]; then
    verdict=error
  else
    verdict=error
  fi
  detail=$(print -r -- "$texts" | tr '\n' ' ' | cut -c1-300)
  # Close our document; quit the app only if this script launched it.
  if [[ $running == true ]]; then
    osascript -e "tell application id \"$app\" to close (every window whose name contains \"$base\") saving no" >/dev/null 2>&1 \
      || osascript -e "tell application id \"$app\" to close (every document whose name contains \"$base\") saving no" >/dev/null 2>&1
  else
    osascript -e "tell application id \"$app\" to quit saving no" >/dev/null 2>&1
    sleep 1
  fi
  print -r -- "$verdict"$'\t'"$detail"
}

apps_for() {
  case ${(L)1} in
    pdf) echo com.apple.Preview ;;
    docx) echo com.apple.Pages com.microsoft.Word ${DOCX_EXTRA_APPS:-} ;;
    xlsx|csv) echo com.apple.Numbers com.microsoft.Excel ;;
    md) echo com.apple.TextEdit ;;
    pptx) echo com.apple.Keynote com.microsoft.Powerpoint ;;
  esac
}

if [[ ${1:-} == --matrix ]]; then
  dir=${2:A}; shift 2; only=""; out=""
  while (( $# )); do
    case $1 in --apps) only=$2; shift 2 ;; --out) out=$2; shift 2 ;; *) shift ;; esac
  done
  [[ -z $out ]] && out=$dir/open-matrix.json
  rows=()
  for f in $dir/*.(pdf|docx|xlsx|csv|md|pptx)(N); do
    for id in $(apps_for ${f:e}); do
      if [[ -n $only && ",${only}," != *",${id},"* && ",${only}," != *",${id/com.apple./com.apple.iWork.},"* ]]; then continue; fi
      res=$(check_one $id $f $dir/open-shots)
      st=${res%%$'\t'*}; de=${res#*$'\t'}
      echo "$st  $id  ${f:t}"
      rows+=("$(python3 -I -c 'import json,sys; print(json.dumps({"file":sys.argv[1],"app":sys.argv[2],"status":sys.argv[3],"detail":sys.argv[4]}, ensure_ascii=False))' "${f:t}" "$id" "$st" "$de")")
    done
  done
  python3 -I - "$out" "${rows[@]}" <<'PY'
import json, sys, collections
out, rows = sys.argv[1], [json.loads(r) for r in sys.argv[2:]]
summary = collections.defaultdict(collections.Counter)
for r in rows:
    summary[r["app"]][r["status"]] += 1
json.dump({"rows": rows, "summary": {k: dict(v) for k, v in summary.items()},
           "total": len(rows), "ok": sum(r["status"] == "ok" for r in rows)}, open(out, "w"), indent=1, ensure_ascii=False)
print(json.dumps({k: dict(v) for k, v in summary.items()}))
PY
  exit 0
fi

[[ $# -ge 2 ]] || { echo "usage: $0 <bundle-id> <file> | --matrix <dir> [--apps ids] --out <json>"; exit 2; }
res=$(check_one $1 $2)
echo ${res%%$'\t'*}
