#!/bin/bash
# tools/release/lib/identity.sh — signing mode → identity, timestamp flag and artefact label (M10.T01, ci-release
# §3/§4; M10.md "Signing modes"). Sourced by build-release.sh, package-dmg.sh and notarize.sh; sign.sh keeps its
# own (Team-ID-aware) resolution from the Nativ port and must agree with this one (both pick the single matching
# certificate of the mode's kind).
#   identity_resolve MODE   sets IDENTITY (SHA-1 or "-"), IDENTITY_NAME, TS_ARG and KIND; returns 1 when the
#                           mode's certificate is missing (dev → caller may fall back to adhoc, M10.md table).
#   release_label MODE APP  prints the artefact label: UNNOTARIZED (adhoc/dev), DEVKEYS (devid built with the
#                           Sparkle test key, never publishable), or nothing (devid + production key).
# No secrets: certificates are looked up by name in the keychain; private keys never leave it.

identity_resolve() {
    local mode="$1" line
    KIND=""; IDENTITY=""; IDENTITY_NAME=""; TS_ARG="--timestamp=none"
    case "$mode" in
        adhoc) IDENTITY="-"; IDENTITY_NAME="ad-hoc"; return 0 ;;
        dev) KIND="Apple Development" ;;
        devid) KIND="Developer ID Application"; TS_ARG="--timestamp" ;;
        *) echo "error: unknown SIGNING_MODE $mode (adhoc|dev|devid)" >&2; return 2 ;;
    esac
    line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$KIND:" | head -n 1 || true)"
    [[ -n "$line" ]] || { echo "error: no \"$KIND\" identity in the keychain" >&2; return 1; }
    IDENTITY="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]\{40\}\) ".*"$/\1/p' <<< "$line")"
    IDENTITY_NAME="$(sed -n 's/^[[:space:]]*[0-9][0-9]*) [0-9A-F]\{40\} "\(.*\)"$/\1/p' <<< "$line")"
}

release_label() {
    local mode="$1" app="$2" root key test
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
    case "$mode" in
        adhoc|dev) echo "UNNOTARIZED"; return ;;
    esac
    key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist" 2>/dev/null || true)"
    test="$(head -n 1 "$root/catalog/test-keys/sparkle-test.pub" 2>/dev/null || true)"
    if [[ -z "$key" || "$key" == "$test" ]]; then echo "DEVKEYS"; else echo ""; fi
}
