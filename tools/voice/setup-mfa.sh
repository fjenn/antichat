#!/usr/bin/env bash
# tools/voice/setup-mfa.sh — the forced aligner behind the AT-282 AC2 reference (A-M9-T05-AT282b;
# tools/voice/word-onsets.py, BargeInFixtureTests). Idempotent; run by tools/bootstrap.sh step 11b and `make mfa`.
#   Montreal Forced Aligner 3.4.3 (MIT, conda-forge) in its own env at $ANTICHAT_MFA_PREFIX (~/.local/share/mfa),
#   plus the english_us_arpa acoustic model 3.0.0, dictionary 3.0.0 and G2P model 2.0.0a (the English ARPA
#   G2P that `mfa model download` picks by default; CC BY 4.0; the 2026-11-11 run used it) in ~/Documents/MFA,
#   checked against the sha256 below. About 1.3 GB env + 0.1 GB models. Dev/test only: nothing here ships.
# Exit: 0 ok; 10 toolchain (micromamba / env); 20 checksum.
set -euo pipefail

MFA_VERSION=3.4.3
PREFIX="${ANTICHAT_MFA_PREFIX:-$HOME/.local/share/mfa}"
MODELS="${MFA_ROOT_DIR:-$HOME/Documents/MFA}/pretrained_models"
# version, sha256 of the english_us_arpa files as downloaded on 2026-11-11 (mfa model download).
VERSIONS="acoustic 3.0.0
dictionary 3.0.0
g2p 2.0.0a"
SUMS="d35ce271ded357d833d2f4b8d1041dc3748b9538567ba13f2c697f4e4126711b  acoustic/english_us_arpa.zip
e8c6c7b036ae2b7c78d2768b8dc6b1f9359175b842956d00b48c53c9c332e6b0  dictionary/english_us_arpa.dict
0ef6a3b288dc0a91a267f98bf556a45bbfeae198e578398e92ac603a61ad46e5  g2p/english_us_arpa.zip"

MFA="$PREFIX/bin/mfa"
if [ -x "$MFA" ] && [ "$("$MFA" version 2>/dev/null)" = "$MFA_VERSION" ]; then
  echo "[ok] mfa $MFA_VERSION at $PREFIX"
else
  MM="$(command -v micromamba || true)"
  if [ -z "$MM" ]; then
    command -v brew >/dev/null || { echo "[fail] micromamba missing and no Homebrew to install it"; exit 10; }
    brew install micromamba
    MM="$(brew --prefix)/opt/micromamba/bin/micromamba"
  fi
  export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/.local/share/mamba}"
  "$MM" create -y -p "$PREFIX" -c conda-forge "montreal-forced-aligner=$MFA_VERSION" python=3.12 || {
    echo "[fail] micromamba create montreal-forced-aligner=$MFA_VERSION"; exit 10; }
  [ "$("$MFA" version)" = "$MFA_VERSION" ] || { echo "[fail] mfa version != $MFA_VERSION"; exit 10; }
  echo "[fix] mfa $MFA_VERSION installed at $PREFIX"
fi

# kaldi / openfst binaries live next to mfa: put the env first on PATH for the downloads.
export PATH="$PREFIX/bin:$PATH"
for kind in acoustic dictionary g2p; do
  f="$(echo "$SUMS" | awk -v k="$kind/" 'index($2, k) == 1 {print $2}')"
  v="$(echo "$VERSIONS" | awk -v k="$kind" '$1 == k {print $2}')"
  [ -f "$MODELS/$f" ] || mfa model download "$kind" english_us_arpa --version "$v"
done
(cd "$MODELS" && echo "$SUMS" | shasum -a 256 -c --status) || {
  echo "[fail] english_us_arpa model checksum (expected:"; echo "$SUMS"; echo ") in $MODELS"; exit 20; }
echo "[ok] english_us_arpa models (acoustic 3.0.0, dictionary 3.0.0, g2p 2.0.0a; sha256 verified) in $MODELS"
