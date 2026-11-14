#!/bin/bash
# tools/release/appcast-test.sh — Sparkle test-key appcast round trip (M0.T12 step 5; ci-release.md §6.1–§6.2;
# P-platform-12 test tools). Never touches the login Keychain: every Sparkle tool gets --ed-key-file.
#   zip the signed app (ditto) → sign_update → generate_appcast → sign_update --verify of the archive with the
#   signature from the appcast enclosure → negative check (a tampered copy must NOT verify).
# Usage: tools/release/appcast-test.sh [APP]   (default build/AntiChat.app)
# Env: SPARKLE_BIN (default: the Sparkle 2.10.1 artefact bundle that SwiftPM unpacked under build/dd),
#      KEY (default catalog/test-keys/sparkle-test.key), OUT (default build/updates).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$ROOT"
APP="${1:-build/AntiChat.app}"
KEY="${KEY:-catalog/test-keys/sparkle-test.key}"
PUB="${KEY%.key}.pub"
OUT="${OUT:-build/updates}"
SPARKLE_BIN="${SPARKLE_BIN:-build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin}"
for tool in sign_update generate_appcast; do
    [[ -x "$SPARKLE_BIN/$tool" ]] || { echo "error: $SPARKLE_BIN/$tool missing (build once so SwiftPM unpacks Sparkle)"; exit 1; }
done
[[ -f "$KEY" && -f "$PUB" ]] || { echo "error: test key missing; run: swift tools/release/make-test-key.swift"; exit 1; }
[[ -d "$APP" ]] || { echo "error: $APP missing"; exit 1; }

version="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
rm -rf "$OUT" && mkdir -p "$OUT"
zip="$OUT/AntiChat-$version.zip"
ditto -c -k --keepParent "$APP" "$zip"
echo "[..] archive $zip ($(stat -f %z "$zip") bytes)"

sig_line="$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEY" "$zip")"
sig="$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEY" -p "$zip")"
echo "[ok] sign_update: $sig_line"

"$SPARKLE_BIN/generate_appcast" --ed-key-file "$KEY" "$OUT" 2>&1 | sed 's/^/[generate_appcast] /'
[[ -f "$OUT/appcast.xml" ]] || { echo "[FAIL] generate_appcast wrote no appcast.xml"; exit 1; }
enclosure_sig="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$OUT/appcast.xml" | head -n 1)"
[[ -n "$enclosure_sig" ]] || { echo "[FAIL] appcast enclosure has no sparkle:edSignature"; exit 1; }
echo "[..] appcast enclosure edSignature=$enclosure_sig"

fail=0
if "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY" "$zip" "$sig" >/dev/null 2>&1; then
    echo "[ok] sign_update --verify (sign_update signature)"
else echo "[FAIL] sign_update --verify rejected the sign_update signature"; fail=1; fi
if "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY" "$zip" "$enclosure_sig" >/dev/null 2>&1; then
    echo "[ok] sign_update --verify (appcast enclosure signature)"
else echo "[FAIL] sign_update --verify rejected the appcast enclosure signature"; fail=1; fi

# The key file's public half must be the committed .pub (what SUPublicEDKey would carry).
derived_pub="$(swift - "$KEY" <<'SWIFT'
import CryptoKit
import Foundation
let seed = try! String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\n")[0]
let k = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: String(seed))!)
print(k.publicKey.rawRepresentation.base64EncodedString())
SWIFT
)"
if [[ "$derived_pub" == "$(head -n 1 "$PUB")" ]]; then echo "[ok] $PUB matches the private seed"
else echo "[FAIL] $PUB does not match $KEY"; fail=1; fi

# Negative: flip one byte in a copy; the same signature must be rejected.
tampered="$OUT/tampered.zip.bin"
cp "$zip" "$tampered"
printf '\xff' | dd of="$tampered" bs=1 seek=100 count=1 conv=notrunc 2>/dev/null
if "$SPARKLE_BIN/sign_update" --verify --ed-key-file "$KEY" "$tampered" "$sig" >/dev/null 2>&1; then
    echo "[FAIL] a tampered archive verified"; fail=1
else echo "[ok] tampered archive rejected"; fi
rm -f "$tampered"

((fail == 0)) && echo "appcast-test: pass" || { echo "appcast-test: FAIL"; exit 1; }
