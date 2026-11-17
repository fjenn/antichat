#!/bin/bash
# tools/release/notarize.sh — notarize + staple one artefact (M10.T01/T02; ci-release §4; pulled forward from
# M10.T08 by the M10 card: credentials exist, Q-003). The P-platform-13 donor (Nativ notarize_macos_release.sh
# @72f4b91) is no longer fetchable upstream; this is an own ~100-line notarytool wrapper with the same steps.
#
# Usage: tools/release/notarize.sh [--mode adhoc|dev|devid] [--out DIR] --app PATH | --dmg PATH
#   adhoc/dev: prints "SKIPPED (UNNOTARIZED)" and exits 0 (nothing is sent anywhere).
#   devid: app → ditto zip → `notarytool submit --wait` → on Accepted `stapler staple` + `stapler validate`
#          on the app; dmg → submit the DMG itself → staple + validate the DMG.
#          Rejected/Invalid → `notarytool log` saved, exit 1 (the caller deletes the artefact).
# Credentials: only the keychain profile ($NOTARY_PROFILE, default AntiChat-notary, created once with
# `xcrun notarytool store-credentials`). No Apple ID, password or API key is ever read from the repo or env.
# $NOTARY_KEYCHAIN (optional): the keychain file that holds the profile (release.yml: the runner's temporary
# keychain); unset = the login keychain.
# Evidence: $OUT/<kind>-<submission id>.json (status), <kind>-<id>.log (Apple's log), staple.txt.
set -euo pipefail
mode="${SIGNING_MODE:-adhoc}"
out="build/release/notary"
profile="${NOTARY_PROFILE:-AntiChat-notary}"
creds=(--keychain-profile "$profile")
[[ -z "${NOTARY_KEYCHAIN:-}" ]] || creds+=(--keychain "$NOTARY_KEYCHAIN")
kind="" target=""
while (($# > 0)); do
    case "$1" in
        --mode) mode="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --app) kind=app; target="$2"; shift 2 ;;
        --dmg) kind=dmg; target="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ -n "$kind" && -e "$target" ]] || { echo "error: --app PATH or --dmg PATH required (got '$target')" >&2; exit 2; }
if [[ "$mode" != devid ]]; then
    echo "notarize: SKIPPED (UNNOTARIZED) — SIGNING_MODE=$mode, $target"
    exit 0
fi
mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/antichat-notary.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The artefact must already carry a Developer ID signature with a secure timestamp (notary requirement).
info="$(codesign -dvv "$target" 2>&1 || true)"
grep -q '^Authority=Developer ID Application:' <<< "$info" || { echo "error: $target is not Developer ID signed" >&2; exit 1; }
grep -q '^Timestamp=' <<< "$info" || { echo "error: $target has no secure timestamp" >&2; exit 1; }

if [[ "$kind" == app ]]; then
    payload="$work/$(basename "$target" .app).zip"
    ditto -c -k --keepParent "$target" "$payload"   # notarytool takes zip/pkg/dmg, never a bare .app
else
    payload="$target"
fi

started=$(date +%s)
echo "notarize: submitting $(basename "$payload") ($(stat -f %z "$payload") bytes) with keychain profile $profile"
set +e
result="$(xcrun notarytool submit "$payload" "${creds[@]}" --wait --timeout 2h --output-format json 2>"$work/submit.err")"
rc=$?
set -e
id="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get("id",""))' "$result" 2>/dev/null || true)"
status="$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get("status",""))' "$result" 2>/dev/null || true)"
stem="$out/$kind-${id:-noid}"
printf '%s\n' "$result" > "$stem.json"
echo "notarize: id=${id:-?} status=${status:-?} ($(( $(date +%s) - started )) s)"
if [[ -n "$id" ]]; then
    xcrun notarytool log "$id" "${creds[@]}" "$stem.log" >/dev/null 2>&1 || true
fi
if ((rc != 0)) || [[ "$status" != Accepted ]]; then
    cat "$work/submit.err" >&2 || true
    [[ -f "$stem.log" ]] && echo "notarize: Apple's log: $stem.log" >&2
    echo "notarize: FAILED ($kind, status=${status:-none})" >&2
    exit 1
fi
# The log lists issues even for an accepted submission (warnings); keep it, fail on none of them.
{
    echo "# $(date -u +%FT%TZ) stapler staple $target"
    xcrun stapler staple "$target"
    echo "# stapler validate"
    xcrun stapler validate "$target"
} > "$out/staple-$kind.txt" 2>&1 || { cat "$out/staple-$kind.txt" >&2; echo "notarize: staple failed" >&2; exit 1; }
echo "notarize: Accepted and stapled ($kind): $target"
