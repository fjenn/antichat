# AntiChat keys: custody, ceremony, rotation (M10.T04; ci-release §6.1; adr-distribution §6)

## The keys
| Key | Signs | Public half pinned in | Private half lives |
|---|---|---|---|
| Developer ID Application: Finn Jennen (446XT9839S) | app, helpers, DMG (codesign) | Apple's chain | owner's login keychain (+ Apple account) |
| Sparkle primary (Ed25519) | DMG archives in the appcast, the appcast itself | `SUPublicEDKey` ← `Config/Keys.release.plist` `SparklePublicEDKey` | encrypted USB ×2 + paper; CI secret `SPARKLE_PRIVATE_KEY` (env `release`) |
| Sparkle backup (Ed25519) | nothing until a rotation | `SparklePublicEDKeyBackup` (record only) | encrypted USB ×2 + paper; never on CI |
| Catalog key A (Ed25519) | `catalog.json` (`.sig`) | `PinnedKeys.keys[0]` ← `CatalogPublicKeyA` | encrypted USB ×2 + paper; CI secret `CATALOG_PRIVATE_KEY_A` (env `release`) |
| Catalog key B (Ed25519) | nothing until a rotation | `PinnedKeys.keys[1]` ← `CatalogPublicKeyB` | encrypted USB ×2 + paper; **never on CI** |
| Notary credentials | notarytool | — | keychain profile `AntiChat-notary` only |

Two public keys are pinned per signer (R-305 AC2): catalog A **or** B verifies (`CatalogVerifier`). Sparkle checks one
EdDSA key per build; its second trust anchor is the Developer ID signature (a new EdDSA key is accepted in an update
signed by the same Developer ID). Forks replace `Config/Keys.*.plist` + `Config/Endpoints.plist` and rebuild.

## Ceremony (owner, once; ~20 min)
1. Two encrypted USB volumes (APFS Encrypted). Wi-Fi off. Working tree clean, on the release branch.
2. `tools/release/key-ceremony.sh --out /Volumes/<USB-1>/antichat-keys`
   - generates the four Ed25519 keys with `catalog-tool keygen` (no Keychain, no network), seeds only on the USB;
   - writes the public keys into `Config/Keys.release.plist`, regenerates `PinnedKeys.swift`, checks `--release-ready`;
   - appends fingerprints (no secrets) to `tools/release/keys-ceremony-log.md`.
3. `ditto /Volumes/<USB-1>/antichat-keys /Volumes/<USB-2>/antichat-keys`; print `ceremony-log.txt` **and** the four
   `.priv` lines on paper; store paper and USB-2 apart from USB-1.
4. Wi-Fi on. Commit `Config/Keys.release.plist`, `PinnedKeys.swift`, `keys-ceremony-log.md` (public data only).
5. When the public repo exists: `gh secret set SPARKLE_PRIVATE_KEY --env release < /Volumes/<USB-1>/antichat-keys/sparkle-primary.priv`
   and `gh secret set CATALOG_PRIVATE_KEY_A --env release < …/catalog-a.priv`. Key B and the Sparkle backup never go to CI.
6. Eject both volumes. Nothing private remains on the Mac (`make audit` release-lint scans the repo for key files).

## Using the keys locally (release day)
- Stable appcast: `FEED=stable SPARKLE_KEY_FILE=/Volumes/<USB-1>/antichat-keys/sparkle-primary.priv RELEASES_URL_PREFIX=https://github.com/<githubRepo>/releases/download/v<ver>/ make appcast`
  (the prefix ends with the release **tag**: GitHub serves assets at `…/download/<tag>/<file>`; without it the enclosure 404s)
- Catalog: `make catalog CATALOG_KEY=/Volumes/<USB-1>/antichat-keys/catalog-a.priv`
- Release build: `make build-release SIGNING_MODE=devid` (now compiles with the release keys; it refused before).

## Rotation and loss (adr-distribution §6)
- **Catalog key A lost/compromised:** sign with B (already pinned), ship a build pinning B + a new A', retire A.
- **Sparkle key lost:** ship an update signed by the same Developer ID carrying the backup key as `SparklePublicEDKey`
  (change the EdDSA key **or** the certificate in one update, never both).
- **Developer ID revoked:** new certificate, same EdDSA key; users download once from the website; data lives outside
  the bundle and survives.
