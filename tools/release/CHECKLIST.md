# AntiChat release checklist (ci-release §8; R-305 AC3)

Copy this list into the release PR / workflow summary and tick each item with an evidence link.
`python3 -I tools/release/checklist-check.py` keeps its structure honest. Keys: [KEYS.md](KEYS.md).
Owner-only first-release steps: [docs/prd/M10-owner-steps.md](../../docs/prd/M10-owner-steps.md).

## Before tagging
1. [ ] Nightly green for 3 consecutive nights on the release branch (local form: the last 3 `make nightly` logs), zero open S0/S1.
2. [ ] Perf smoke within NFR on the T1 and T3 caps; no regression > 5 % vs the last release (`make perf-compare`).
3. [ ] Offline test, clean install, upgrade from the last 2 releases, uninstall: green (`make test-install CASE=clean,move,upgrade,uninstall ENV=tart`).
4. [ ] R-241 audit green; ChildSafetyCheck calibration report attached (NFR-F1/F2/F6/F7).
5. [ ] Copy deck in sync (`copy-sync`); screenshots pass the parity rubric with the per-screen bar met.
6. [ ] `ACKNOWLEDGMENTS.md` regenerated (`tools/acknowledgments.py`); licences unchanged or reviewed.
7. [ ] Release notes `notes/<ver>.md` + What's-new `notes/<ver>.json` (3–5 items) written (`notes-check.py`).
8. [ ] Catalog current, not expiring within 30 days, signed with production key A (`verify-catalog.swift … Config/Keys.release.plist`).

## Pipeline (`tools/release/release.sh`, the same steps as `release.yml`)
9. [ ] `make build-release SIGNING_MODE=devid` → inside-out sign → verify-signing (release keys compiled in).
10. [ ] Notarize + staple the app → DMG → sign → notarize + staple the DMG → `spctl` accepted (Notarized Developer ID).
11. [ ] `SHA256SUMS` + `SHA256SUMS.sig`; `FEED=stable make appcast` (phased rollout, signed feed); GitHub Release **draft** with DMG + sums.
12. [ ] Clean-Mac smoke in a fresh VM: download from the draft URL, standard first-open dialog only, Move to Applications, onboarding to first chat (`TIER=min`).
13. [ ] Update smoke: previous release in the VM → staged appcast → updates → chats and models intact.

## Publish (only after 12 and 13)
14. [ ] Publish the GitHub Release → deploy the site (`make site-deploy-prod CONFIRM=owner`) → `sign_update --verify` the live `appcast.xml`.
15. [ ] Relay: promote the preview to production if `relay/` changed; `/v1/health` OK; E2E fixture against production.
16. [ ] Watch 48 h: issue triage, crash reports users chose to send; pause the phased rollout (pull the appcast item) on any S0.

## First public release only (owner)
17. [x] Developer ID Application certificate + notarytool keychain profile `AntiChat-notary` (done 2026-11).
18. [ ] Production Sparkle and catalog keys from the key ceremony ([KEYS.md](KEYS.md)); public keys compiled in; custody log signed off.
19. [ ] `COMPOSIO_API_KEY`, `INSTALL_ID_HMAC_SECRET`, Upstash variables set in Vercel by the owner.
20. [ ] Domain, support/abuse/security inboxes (`Config/Hosting.json` → `set-hosting.py`), lawyer review of the legal and Evil pages.

## Pulling a release
Remove its `<item>` (`appcast-post.py --pull <ver>`), re-sign the feed (`appcast.sh` does both), redeploy the site.
Earlier releases stay on GitHub Releases and are linked from the changelog.

## Certificate-revocation contingency (adr-distribution §6)
1. Request a new Developer ID Application certificate; keep the **same** Sparkle EdDSA key.
2. Build, sign and notarize with the new certificate; publish it as a website download (Sparkle rejects a changed
   signing identity together with a changed key, so never change both in one update).
3. Users download once from the website; their data lives outside the bundle (`~/Library/Application Support/AntiChat`) and survives.
