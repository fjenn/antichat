#!/bin/bash
# Ported from Blaizzy/nativ@72f4b91:scripts/sign_macos_release.sh (MIT, (c) Prince Canuma; licence text in
# ACKNOWLEDGMENTS.md). P-platform-13, ci-release.md §3, M0.T12 step 1.
# AntiChat patches (see "ANTICHAT:" comments):
#   - modes adhoc | dev | devid instead of Nativ's identity/Team-ID inference from Nativ.xcodeproj;
#   - per-binary entitlements from tools/release/entitlements/ (app, AntiChatEngine.xpc, llama-server,
#     sd-server/sd-cli) instead of one Configuration/Nativ.entitlements; no keychain-access-groups,
#     no provisioning profile (AntiChat uses neither);
#   - third-party nested code (Sparkle's Autoupdate, Updater.app, Downloader.xpc/Installer.xpc) keeps its own
#     entitlements (--preserve-metadata=entitlements, Sparkle "Sandboxing" / code-signing docs);
#   - Mach-Os are signed deepest path first (Nativ relied on find order);
#   - the File tools XPC services (M6.T17) are signed with App/FileToolsHelper/FileTools[Net].entitlements;
#   - --bundle DIR signs a non-app tree (the downloadable video runtime): every Mach-O, executables with the
#     video-runtime entitlements, after stripping signatures that wheels ship;
#   - never --deep for signing (D-06); --deep is used for verification only.
#   - disk-image signing is left to M10 (G-061); the DMG step is not part of the M0 slice.
#
# Usage:
#   tools/release/sign.sh --mode adhoc|dev|devid [--identity ID] [--team-id ID] [--report FILE] --app build/AntiChat.app
#   tools/release/sign.sh --mode adhoc [--entitlements PLIST] [--report FILE] --bundle build/runtimes/video-runtime-unzipped
#   (positional TARGET = --app TARGET, for compatibility with the Nativ interface)
# Env: ANTICHAT_TEAM_ID (dev/devid, instead of --team-id), CODE_SIGN_IDENTITY (instead of --identity),
#      ADHOC_LV_EXEMPT=0 to drop the ad-hoc-only library-validation exemption (A-M0-T12a; default 1).
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

fail() {
    echo "error: $*" >&2
    exit 1
}

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
entitlements_directory="$script_directory/entitlements"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
mode=""
identity="${CODE_SIGN_IDENTITY:-}"
team_id="${ANTICHAT_TEAM_ID:-}"
target_path=""
target_kind=""
bundle_entitlements="$entitlements_directory/video-runtime.plist"
report=""

while (($# > 0)); do
    case "$1" in
        --mode) (($# >= 2)) || fail "--mode requires a value"; mode="$2"; shift 2 ;;
        --identity) (($# >= 2)) || fail "--identity requires a value"; identity="$2"; shift 2 ;;
        --team-id) (($# >= 2)) || fail "--team-id requires a value"; team_id="$2"; shift 2 ;;
        --app) (($# >= 2)) || fail "--app requires a value"; target_path="$2"; target_kind=app; shift 2 ;;
        --bundle) (($# >= 2)) || fail "--bundle requires a value"; target_path="$2"; target_kind=tree; shift 2 ;;
        --entitlements) (($# >= 2)) || fail "--entitlements requires a value"; bundle_entitlements="$2"; shift 2 ;;
        --report) (($# >= 2)) || fail "--report requires a value"; report="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --*) fail "unknown option: $1" ;;
        *) [[ -z "$target_path" ]] || fail "more than one target"; target_path="$1"; target_kind=app; shift ;;
    esac
done

[[ -n "$target_path" ]] || { usage >&2; exit 2; }
# ANTICHAT: `--identity -` (the M0.T07 spelling) means ad-hoc.
if [[ -z "$mode" ]]; then
    [[ "$identity" == "-" ]] && mode=adhoc || fail "--mode adhoc|dev|devid is required"
fi
[[ -e "$target_path" ]] || fail "target not found: $target_path"
target_path="$(cd "$(dirname "$target_path")" && pwd -P)/$(basename "$target_path")"
if [[ "$target_kind" == app ]]; then
    [[ -d "$target_path/Contents" ]] || fail "target must be a macOS app bundle: $target_path"
else
    [[ -d "$target_path" ]] || fail "--bundle target must be a directory: $target_path"
fi

# ---- identity (ANTICHAT: modes replace Nativ's Xcode build-setting inference) ----
case "$mode" in
    adhoc)
        identity="-"
        timestamp_arguments=(--timestamp=none)
        ;;
    dev|devid)
        if [[ "$mode" == dev ]]; then
            certificate_kind="Apple Development"; timestamp_arguments=(--timestamp=none)
        else
            certificate_kind="Developer ID Application"; timestamp_arguments=(--timestamp)
        fi
        if [[ -z "$identity" ]]; then
            command -v openssl >/dev/null 2>&1 || fail "openssl is required to resolve a Team ID"
            matching_hashes=(); matching_names=()
            while IFS= read -r identity_candidate; do
                certificate_hash="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]\{40\}\) ".*"$/\1/p' <<< "$identity_candidate")"
                certificate_name="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p' <<< "$identity_candidate")"
                [[ -n "$certificate_hash" && "$certificate_name" == "$certificate_kind:"* ]] || continue
                if [[ -n "$team_id" ]]; then
                    certificate_subject="$(security find-certificate -c "$certificate_name" -p 2>/dev/null |
                        openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true)"
                    [[ "$certificate_subject" == *"OU=$team_id"* ]] || continue
                fi
                matching_hashes+=("$certificate_hash"); matching_names+=("$certificate_name")
            done < <(security find-identity -v -p codesigning 2>/dev/null)
            ((${#matching_hashes[@]} > 0)) || fail "no $certificate_kind certificate found${team_id:+ for Team ID $team_id}"
            if ((${#matching_hashes[@]} > 1)); then
                printf '  %s\n' "${matching_names[@]}" >&2
                fail "multiple $certificate_kind certificates; pass --identity or --team-id"
            fi
            identity="${matching_hashes[0]}"
            echo "Resolved signing identity: ${matching_names[0]}"
        fi
        identity_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$identity" | head -n 1 || true)"
        [[ -n "$identity_line" ]] || fail "codesigning identity not found: $identity"
        if [[ "$mode" == devid && "$identity_line" != *"Developer ID Application:"* ]]; then
            fail "devid mode needs a Developer ID Application identity"
        fi
        ;;
    *) fail "unknown mode: $mode (adhoc|dev|devid)" ;;
esac

report_line() {  # path<TAB>entitlements — the evidence list (M0.T12 AT artefacts)
    [[ -z "$report" ]] || printf '%s\t%s\n' "${1#"$target_path"/}" "$2" >> "$report"
}
if [[ -n "$report" ]]; then
    mkdir -p "$(dirname "$report")"
    printf '# sign.sh --mode %s %s (%s)\n' "$mode" "$target_path" "$(date -u +%FT%TZ)" >> "$report"
fi

# ANTICHAT: Nativ signs every Mach-O with no entitlements; we pass per-binary entitlements or preserve them.
sign_code() {  # sign_code <path> <entitlements plist | preserve | none>
    local target="$1" entitlements="$2"
    local arguments=(--force --sign "$identity" --options runtime "${timestamp_arguments[@]}")
    case "$entitlements" in
        none) ;;
        preserve) arguments+=(--preserve-metadata=entitlements) ;;
        *) arguments+=(--entitlements "$entitlements") ;;
    esac
    codesign "${arguments[@]}" "$target"
    local label="${entitlements#"$repository_root"/}"; label="${label#"$work_directory"/}"
    report_line "$target" "$label"
}

is_macho() {
    local file_type
    file_type="$(file -b "$1" 2>/dev/null || true)"
    [[ "$file_type" == Mach-O* ]]
}

# Deepest paths first (ANTICHAT: explicit ordering; Nativ relied on find's traversal order).
list_deepest_first() {  # list_deepest_first <find args…> → newline-separated paths
    find "$@" | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-
}

work_directory="$(mktemp -d "${TMPDIR:-/tmp}/antichat-sign.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

# Ad-hoc only (A-M0-T12a): merge entitlements/adhoc-extra.plist into a per-binary plist.
entitlements_for_mode() {  # entitlements_for_mode <plist> → path to the plist to use
    local base="$1" extra="$entitlements_directory/adhoc-extra.plist" merged key
    if [[ "$mode" != adhoc || "${ADHOC_LV_EXEMPT:-1}" == 0 || ! -f "$extra" ]]; then
        echo "$base"; return
    fi
    merged="$work_directory/$(basename "$base" .plist)+adhoc-extra.plist"  # the EXIT trap removes the directory
    # Runs inside $(...), where bash clears errexit: every step returns non-zero explicitly, and callers
    # assign the result to a variable first so `set -e` sees that status.
    local keys
    keys="$(plutil -convert json -o - "$extra" | /usr/bin/python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')" || return 1
    [[ -n "$keys" ]] || return 1
    cp "$base" "$merged" || return 1
    for key in $keys; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$merged" >/dev/null 2>&1 || true
        /usr/libexec/PlistBuddy -c "Add :$key bool true" "$merged" || return 1
    done
    plutil -lint "$merged" >/dev/null || return 1
    echo "$merged"
}

# ------------------------------------------------------------------ tree mode (runtime zips)
if [[ "$target_kind" == tree ]]; then
    [[ -f "$bundle_entitlements" ]] || fail "entitlements not found: $bundle_entitlements"
    count=0
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        is_macho "$candidate" || continue
        # Wheels can ship stray (often invalid) signatures; strip before re-signing (M0.T07 failure mode).
        codesign --remove-signature "$candidate" 2>/dev/null || true
        if [[ "$(file -b "$candidate")" == *executable* ]]; then
            sign_code "$candidate" "$bundle_entitlements"
        else
            sign_code "$candidate" none
        fi
        count=$((count + 1))
    done < <(list_deepest_first "$target_path" -type f)
    ((count > 0)) || fail "no Mach-O files under $target_path"
    failed=0
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && is_macho "$candidate" || continue
        codesign --verify --strict "$candidate" || { echo "verify failed: $candidate" >&2; failed=$((failed + 1)); }
    done < <(find "$target_path" -type f)
    ((failed == 0)) || fail "$failed Mach-O files failed codesign --verify --strict"
    echo "Signed and verified $count Mach-O files ($mode, hardened runtime): $target_path"
    exit 0
fi

# ------------------------------------------------------------------ app mode
app_path="$target_path"
app_entitlements_source="$entitlements_directory/AntiChat.plist"
# ANTICHAT: the XcodeGen-owned App/AntiChat/AntiChat.entitlements and the release plist must agree.
if [[ -f "$repository_root/App/AntiChat/AntiChat.entitlements" ]]; then
    a="$(plutil -convert json -o - "$repository_root/App/AntiChat/AntiChat.entitlements")"
    b="$(plutil -convert json -o - "$app_entitlements_source")"
    [[ "$a" == "$b" ]] || fail "App/AntiChat/AntiChat.entitlements and $app_entitlements_source differ"
fi

# Bundles inside out, including the app. Their main executables are signed with their bundles.
code_bundles=()
bundle_executables=()
while IFS= read -r code_bundle; do
    [[ -n "$code_bundle" ]] || continue
    # A versioned framework's top level (Foo.framework → Versions/Current) is the same code as Versions/X;
    # sign the version directory (Sparkle's documented order) and skip duplicates via the symlinked root.
    code_bundles+=("$code_bundle")
    if [[ "$code_bundle" == *.framework ]]; then
        info_plist="$code_bundle/Resources/Info.plist"
        executable_directory="$code_bundle"
    else
        info_plist="$code_bundle/Contents/Info.plist"
        executable_directory="$code_bundle/Contents/MacOS"
    fi
    if [[ ! -f "$info_plist" ]]; then
        info_plist="$code_bundle/Info.plist"
        executable_directory="$code_bundle"
    fi
    executable_name="$(plutil -extract CFBundleExecutable raw -o - "$info_plist" 2>/dev/null || true)"
    if [[ -n "$executable_name" && -f "$executable_directory/$executable_name" ]]; then
        bundle_executables+=("$executable_directory/$executable_name")
    fi
done < <(list_deepest_first "$app_path" -type d \
    \( -name '*.framework' -o -name '*.xpc' -o -name '*.appex' -o -name '*.plugin' -o -name '*.app' \))

# Entitlements for a loose Mach-O (not a bundle's main executable).
entitlements_for_file() {
    local path="$1" relative="${1#"$app_path"/}"
    case "$relative" in
        Contents/Helpers/llama-server) echo "$entitlements_directory/llama-server.plist" ;;
        Contents/Helpers/sd-server|Contents/Helpers/sd-cli) echo "$entitlements_directory/sd-server.plist" ;;
        # M1.T12: our orphan watchdog (Darwin + Swift runtime only): hardened runtime, no entitlements.
        Contents/Helpers/llama-watchdog) echo none ;;
        */Frameworks/*) echo preserve ;;  # third-party (Sparkle Autoupdate, onnxruntime): keep their entitlements
        *) echo none ;;
    esac
}
entitlements_for_bundle() {
    local relative="${1#"$app_path"/}"
    case "$relative" in
        Contents/XPCServices/AntiChatEngine.xpc) entitlements_for_mode "$entitlements_directory/AntiChatEngine.plist" ;;
        # M1.T12 (A-M1-T12a): trampoline job; it execs AntiChatEngine.xpc's binary, whose own signature and
        # entitlements then apply. The trampoline itself needs none.
        Contents/XPCServices/AntiChatEngineStandby.xpc) echo none ;;
        # M6.T17 (A-M6-11): the App-Sandboxed File tools services keep exactly their XcodeGen entitlements (sandbox,
        # read-only Runtimes exception, network.client only in the Net variant). No library-validation exemption: they
        # load no non-system library (the interpreter they spawn carries its own, sign-runtime.sh).
        # A-M6-T21a (a): one bundle per slot; every slot of a variant signs with the same file (gen-filetools-entitlements --check).
        Contents/XPCServices/AntiChatFileToolsSlot1.xpc) echo "$repository_root/App/FileToolsHelper/FileTools.entitlements" ;;
        Contents/XPCServices/AntiChatFileToolsSlot2.xpc) echo "$repository_root/App/FileToolsHelper/FileTools.entitlements" ;;
        Contents/XPCServices/AntiChatFileToolsSlot3.xpc) echo "$repository_root/App/FileToolsHelper/FileTools.entitlements" ;;
        Contents/XPCServices/AntiChatFileToolsNetSlot1.xpc) echo "$repository_root/App/FileToolsHelper/FileToolsNet.entitlements" ;;
        Contents/XPCServices/AntiChatFileToolsNetSlot2.xpc) echo "$repository_root/App/FileToolsHelper/FileToolsNet.entitlements" ;;
        Contents/XPCServices/AntiChatFileToolsNetSlot3.xpc) echo "$repository_root/App/FileToolsHelper/FileToolsNet.entitlements" ;;
        *) echo preserve ;;  # Sparkle.framework, Updater.app, Downloader.xpc/Installer.xpc (Sparkle docs)
    esac
}

native_count=0
while IFS= read -r native_file; do
    [[ -n "$native_file" ]] || continue
    is_macho "$native_file" || continue
    is_bundle_executable=false
    for bundle_executable in ${bundle_executables[@]+"${bundle_executables[@]}"}; do
        # Compare file identities so versioned framework symlinks also match.
        if [[ "$native_file" -ef "$bundle_executable" ]]; then is_bundle_executable=true; break; fi
    done
    [[ "$is_bundle_executable" == false ]] || continue
    file_entitlements="$(entitlements_for_file "$native_file")"
    sign_code "$native_file" "$file_entitlements"
    native_count=$((native_count + 1))
done < <(list_deepest_first "$app_path" -type f)

for code_bundle in ${code_bundles[@]+"${code_bundles[@]}"}; do
    [[ "$code_bundle" != "$app_path" ]] || continue
    bundle_entitlements_path="$(entitlements_for_bundle "$code_bundle")"
    sign_code "$code_bundle" "$bundle_entitlements_path"
done

# The app last (never --deep, D-06).
app_entitlements_path="$(entitlements_for_mode "$app_entitlements_source")"
sign_code "$app_path" "$app_entitlements_path"

while IFS= read -r native_file; do
    [[ -n "$native_file" ]] && is_macho "$native_file" || continue
    codesign --verify --strict "$native_file"
done < <(find "$app_path" -type f)
codesign --verify --deep --strict --verbose=2 "$app_path"

app_entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
[[ "$app_entitlements" != *"com.apple.security.get-task-allow"* ]] || \
    fail "the signed app still contains the development-only get-task-allow entitlement"
[[ "$app_entitlements" == *"com.apple.security.device.audio-input"* ]] || \
    fail "the signed app is missing the audio-input entitlement"
if [[ "$mode" != adhoc && "$app_entitlements" == *"disable-library-validation"* ]]; then
    fail "the library-validation exemption is ad-hoc only (A-M0-T12a)"
fi

echo "Signed and verified ($mode): $native_count loose Mach-O, $((${#code_bundles[@]} - 1)) nested bundles, app: $app_path"
