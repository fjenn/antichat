#!/bin/bash
# tools/release/verify-signing.sh — signing verification step (ci-release.md §3 "Verification step"; M0.T12 step 2;
# P-platform-13 adapter "verify-launch script"). Read-only: never signs or changes the target.
#
# Usage: tools/release/verify-signing.sh [--mode adhoc|dev|devid] [--out DIR] [--tree] [--pre-notary] TARGET
#   TARGET   an app bundle (default) or, with --tree, a non-bundle directory (the unzipped video runtime).
#   --mode   expected signing mode (default: $SIGNING_MODE, else adhoc).
#   --pre-notary  devid only: skip the Gatekeeper check (3), which can pass only after notarization + stapling
#            (build-release.sh runs verify twice: before notarizing and after stapling).
#   --out    evidence directory (default build/release/verify): codesign-dvvv.txt, spctl.txt, verify.txt,
#            quarantine.txt, verify.json. Files are appended for --tree so the app and the runtime share them.
# Checks (exit 1 if any fails):
#   1. codesign --verify --strict --deep-verify-only TARGET; if this codesign does not accept that spelling
#      (ci-release.md §3), the same with --deep, for verification only (M0.T12 step 2). Tree mode: per file.
#   2. codesign -dvvv for every Mach-O: one signing identity for all (adhoc: Signature=adhoc and no Team ID;
#      dev/devid: one TeamIdentifier), the hardened-runtime flag (0x10000) on every one, and a secure
#      timestamp in devid mode.
#   3. spctl -a -vv -t exec (app only): devid must be accepted as "Notarized Developer ID"; adhoc/dev must
#      be rejected, and only for the ad-hoc / unnotarized reason, which `syspolicy_check distribution`
#      names (macOS 26 spctl prints no source= line for ad-hoc code). Both outputs recorded verbatim.
#   4. no com.apple.quarantine attribute anywhere under TARGET.
#   5. entitlements (M10.T01, ci-release §3 matrix): no Mach-O carries allow-jit or get-task-allow; in app mode
#      disable-library-validation appears only in adhoc builds (A-M0-T12a); the app and AntiChatEngine.xpc carry
#      device.audio-input. Evidence: entitlements.txt.
set -euo pipefail

mode="${SIGNING_MODE:-adhoc}"
out="build/release/verify"
tree=false
pre_notary=false
target=""
while (($# > 0)); do
    case "$1" in
        --mode) mode="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --tree) tree=true; shift ;;
        --pre-notary) pre_notary=true; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; exit 0 ;;
        --*) echo "error: unknown option $1" >&2; exit 2 ;;
        *) target="$1"; shift ;;
    esac
done
[[ -n "$target" && -d "$target" ]] || { echo "error: target directory required" >&2; exit 2; }
case "$mode" in adhoc|dev|devid) ;; *) echo "error: bad mode $mode" >&2; exit 2 ;; esac
mkdir -p "$out"
dvvv="$out/codesign-dvvv.txt"; spctl_out="$out/spctl.txt"; verify_out="$out/verify.txt"; qfile="$out/quarantine.txt"
if [[ "$tree" == false ]]; then : > "$dvvv"; : > "$verify_out"; : > "$qfile"; fi

failures=()
fail_check() { failures+=("$1"); echo "[FAIL] $1"; }
pass_check() { echo "[ok]   $1"; }

is_macho() { local t; t="$(file -b "$1" 2>/dev/null || true)"; [[ "$t" == Mach-O* ]]; }

# ---- 1. structural verification
deep_flag=""
if [[ "$tree" == false ]]; then
    {
        echo "# $(date -u +%FT%TZ) codesign --verify --strict --deep-verify-only $target"
        if codesign --verify --strict --deep-verify-only --verbose=2 "$target" 2>&1; then
            deep_flag="--deep-verify-only"
        else
            echo "# --deep-verify-only not accepted (or failed); retrying with --deep (verification only, ci-release §3)"
            if codesign --verify --strict --deep --verbose=2 "$target" 2>&1; then deep_flag="--deep"; fi
        fi
        echo "# result: ${deep_flag:-FAILED}"
    } >> "$verify_out" 2>&1
    if [[ -n "$deep_flag" ]]; then pass_check "codesign --verify --strict $deep_flag"; else fail_check "codesign --verify --strict --deep"; fi
fi

# ---- 2. per-Mach-O identity + runtime flag
total=0; bad_verify=0; bad_runtime=0; bad_ts=0
identities=""
while IFS= read -r f; do
    [[ -n "$f" ]] && is_macho "$f" || continue
    total=$((total + 1))
    info="$(codesign -dvvv "$f" 2>&1 || true)"
    {
        echo "=== ${f}"
        echo "$info" | grep -E '^(Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier|Timestamp|Runtime Version)=' || true
    } >> "$dvvv"
    codesign --verify --strict "$f" >/dev/null 2>&1 || { bad_verify=$((bad_verify + 1)); echo "verify failed: $f" >> "$verify_out"; }
    flags="$(sed -n 's/.*flags=\(0x[0-9a-f]*\).*/\1/p' <<< "$info" | head -n 1)"
    if [[ -z "$flags" ]] || (( (flags & 0x10000) == 0 )); then
        bad_runtime=$((bad_runtime + 1)); echo "no runtime flag: $f ($flags)" >> "$verify_out"
    fi
    if grep -q '^Signature=adhoc' <<< "$info"; then
        id="adhoc"
    else
        id="team:$(sed -n 's/^TeamIdentifier=//p' <<< "$info")|$(sed -n 's/^Authority=//p' <<< "$info" | head -n 1)"
    fi
    if [[ "$mode" == devid ]] && ! grep -q '^Timestamp=' <<< "$info"; then bad_ts=$((bad_ts + 1)); fi
    identities="$identities$id"$'\n'
done < <(find "$target" -type f)
unique_ids="$(printf '%s' "$identities" | sort -u | sed '/^$/d')"
n_ids="$(printf '%s\n' "$unique_ids" | sed '/^$/d' | wc -l | tr -d ' ')"
label="$( [[ "$tree" == true ]] && echo "tree" || echo "app" )"
((total > 0)) || fail_check "$label: no Mach-O found"
((bad_verify == 0)) && pass_check "$label: codesign --verify --strict on $total Mach-O" || fail_check "$label: $bad_verify/$total Mach-O fail --verify --strict"
((bad_runtime == 0)) && pass_check "$label: hardened runtime flag 0x10000 on $total/$total" || fail_check "$label: $bad_runtime Mach-O without the runtime flag"
# dev/devid: the one identity must be a real one (a Team ID and an authority), never ad-hoc.
if [[ "$n_ids" == 1 ]] && { { [[ "$mode" == adhoc ]] && [[ "$unique_ids" == adhoc ]]; } ||
                            { [[ "$mode" != adhoc ]] && [[ "$unique_ids" =~ ^team:[A-Z0-9]+\|.+ ]]; }; }; then
    pass_check "$label: one signing identity for all Mach-O ($unique_ids)"
else
    fail_check "$label: identities differ or wrong for mode $mode: $(tr '\n' ' ' <<< "$unique_ids")"
fi
[[ "$mode" != devid || $bad_ts == 0 ]] || fail_check "$label: $bad_ts Mach-O without a secure timestamp"

# ---- 3. Gatekeeper assessment (app only)
spctl_verdict="n/a"
if [[ "$tree" == false ]]; then
    set +e
    spctl_text="$(spctl -a -vv -t exec "$target" 2>&1)"; spctl_rc=$?
    set -e
    { echo "# $(date -u +%FT%TZ) spctl -a -vv -t exec $target (exit $spctl_rc)"; echo "$spctl_text"; } > "$spctl_out"
    if [[ "$mode" == devid && "$pre_notary" == true ]]; then
        spctl_verdict="pending-notarization"; echo "[..]   spctl: skipped before notarization (--pre-notary)"
    elif [[ "$mode" == devid ]]; then
        if ((spctl_rc == 0)) && grep -q 'source=Notarized Developer ID' <<< "$spctl_text"; then
            spctl_verdict="accepted"; pass_check "spctl: accepted (Notarized Developer ID)"
        else
            spctl_verdict="unexpected"; fail_check "spctl: devid build not accepted as notarized: $spctl_text"
        fi
    else
        # macOS 26 prints only "<app>: rejected" (no source= line) for an ad-hoc app, so the reason comes from
        # `syspolicy_check distribution` (macOS 14+): the rejection is accepted only if its findings are
        # exactly the ad-hoc / unnotarized ones. Any other finding (invalid or broken signature, missing
        # sealed resource, unsigned nested code, …) is a signing defect and fails.
        set +e
        policy_text="$(/usr/bin/syspolicy_check distribution "$target" 2>&1)"; policy_rc=$?
        set -e
        { echo; echo "# syspolicy_check distribution $target (exit $policy_rc)"; echo "$policy_text"; } >> "$spctl_out"
        findings="$(awk 'NR>1 && /^[A-Za-z]/ {print}' <<< "$policy_text" | sed 's/[[:space:]]*$//' | sort -u)"
        allowed='^(Adhoc Signed App|Notary Ticket Missing|Development Certificate|Apple Development Signed App)$'
        unexpected="$(grep -Ev "$allowed" <<< "$findings" | sed '/^$/d' || true)"
        echo "# findings: $(tr '\n' ';' <<< "$findings") unexpected: ${unexpected:-none}" >> "$spctl_out"
        if ((spctl_rc != 0)) && grep -q 'rejected' <<< "$spctl_text" && [[ -n "$findings" && -z "$unexpected" ]] && \
           { [[ "$mode" != adhoc ]] || grep -q '^Adhoc Signed App$' <<< "$findings"; }; then
            spctl_verdict="rejected-expected"
            pass_check "spctl: rejected (exit $spctl_rc) only for: $(tr '\n' ';' <<< "$findings")"
        else
            spctl_verdict="unexpected"
            fail_check "spctl: unexpected (exit $spctl_rc: $spctl_text; findings: $(tr '\n' ';' <<< "$findings"))"
        fi
    fi
fi

# ---- 5. entitlements
ent_out="$out/entitlements.txt"
[[ "$tree" == true ]] || : > "$ent_out"
bad_ent=0
while IFS= read -r f; do
    [[ -n "$f" ]] && is_macho "$f" || continue
    ents="$(codesign -d --entitlements :- "$f" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || echo '{}')"
    [[ -n "$ents" ]] || ents='{}'
    echo "${f#"$target"/}	$ents" >> "$ent_out"
    for key in com.apple.security.cs.allow-jit com.apple.security.get-task-allow; do
        if [[ "$ents" == *"\"$key\""* ]]; then bad_ent=$((bad_ent + 1)); echo "forbidden $key: $f" >> "$verify_out"; fi
    done
    if [[ "$tree" == false && "$mode" != adhoc && "$ents" == *disable-library-validation* ]]; then
        bad_ent=$((bad_ent + 1)); echo "library-validation exemption outside adhoc: $f" >> "$verify_out"
    fi
done < <(find "$target" -type f)
if [[ "$tree" == false ]]; then
    for rel in "Contents/MacOS/AntiChat" "Contents/XPCServices/AntiChatEngine.xpc/Contents/MacOS/AntiChatEngine"; do
        [[ -f "$target/$rel" ]] || continue
        codesign -d --entitlements :- "$target/$rel" 2>/dev/null | grep -q 'com.apple.security.device.audio-input' || {
            bad_ent=$((bad_ent + 1)); echo "missing device.audio-input: $rel" >> "$verify_out"; }
    done
fi
((bad_ent == 0)) && pass_check "$label: entitlements match the matrix (no allow-jit/get-task-allow; LV exemption adhoc-only)" \
    || fail_check "$label: $bad_ent entitlement problem(s), see $verify_out"

# ---- 4. quarantine
q="$(xattr -lr "$target" 2>/dev/null | grep -c com.apple.quarantine || true)"
echo "# $(date -u +%FT%TZ) xattr -lr $target | grep -c com.apple.quarantine = $q" >> "$qfile"
[[ "$q" == 0 ]] && pass_check "$label: zero com.apple.quarantine attributes" || fail_check "$label: $q quarantine attributes"

python3 -I - "$out/verify.json" "$label" "$target" "$mode" "$total" "$bad_verify" "$bad_runtime" "$unique_ids" \
    "$spctl_verdict" "$q" "${deep_flag:-}" "${#failures[@]}" <<'PY'
import json, os, sys
path, label, target, mode, total, bad_v, bad_rt, ids, spctl, q, deep, nfail = sys.argv[1:]
data = json.load(open(path)) if os.path.exists(path) and label == "tree" else {}
data[label] = {"target": target, "mode": mode, "macho": int(total), "verify_failed": int(bad_v),
               "without_runtime_flag": int(bad_rt), "identities": [i for i in ids.split("\n") if i],
               "spctl": spctl, "quarantine": int(q), "deep_verify_flag": deep or None, "pass": nfail == "0"}
json.dump(data, open(path, "w"), indent=2)
PY
if ((${#failures[@]} > 0)); then echo "verify-signing: ${#failures[@]} check(s) failed"; exit 1; fi
echo "verify-signing: all checks passed ($label, $mode, $total Mach-O)"
