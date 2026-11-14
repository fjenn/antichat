#!/usr/bin/env bash
# M1.T03 definition of done: `make design-gen && git diff --exit-code` (generated files reproducible).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
make design-gen
git diff --exit-code -- App/AntiChat/Localizable.xcstrings Packages/Design/Sources/AntiChatDesign
echo "design-gen reproducible: no diff in the generated files"
