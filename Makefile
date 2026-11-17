# AntiChat Makefile (environment.md §8; M0.T00 + M0.T01). Targets of later milestones are
# added by the task that first needs them.
SHELL := /bin/bash
ROOT := $(abspath .)
ENV := source $(ROOT)/tools/env.sh &&
TIER ?= min
FIXTURES ?= $(ROOT)/fixtures
PY := $(ROOT)/tools/.venv/bin/python
# xcbeautify when installed (bootstrap), else raw xcodebuild output (M1.T02).
BEAUTIFY := $(shell command -v xcbeautify >/dev/null 2>&1 && echo 'xcbeautify --quiet' || echo cat)

.PHONY: mfa filetools-runtime-ready tools-venv m0-gate build-release build-tryout sign verify-signing notarize release-preflight dmg appcast test-release-tools site site-test site-deploy-preview site-deploy-prod bench-release runtime-video audit-vendor vendor-bump vendor-report bootstrap pins-verify binaries stage-binaries stub-models models-dev models-clean build test-unit test-unit-selftest xcodeproj fixtures runtime-video-test runtime-filetools \
	catalog skills-index site-dev catalog-fixtures audit audit-selftest dev-catalog test-integration-stub test-install test-integration-real test-ui perf perf-all build-perf perf-compare perf-targets soak bench test-offline test-visual design-gen run vendor-js vendor-fonts relay-dev relay-test bundle-secret-scan

m0-gate: ; tools/m0/$(shell echo $(AT) | tr A-Z a-z).sh

# Vendored-donor checks (M0.T02 step 10; upstream.md §3.4, §4). verify re-fetches upstream unless OFFLINE=1.
audit-vendor: ; tools/vendor-sync verify && python3 -I tools/ci/vendored-allowlist.py  # verify runs patch-lint

# Vendored-donor bump / upstream report (upstream.md §4, §8; rehearsed in M0.T03). ARGS=--no-branch stays on
# the current branch (rehearsal); conflicts → resolve, then `tools/vendor-sync finish $(NAME)`.
vendor-bump: ; tools/vendor-sync bump $(NAME) $(REF) $(ARGS)
vendor-report: ; tools/vendor-sync report $(ARGS) $(NAME)

# Video runtime (M0.T07, P-media-11): python-build-standalone + hash-locked wheels + vendored FastVideo closure +
# antichat_video → build/runtimes/video-runtime-<ver>.zip. ARGS=--sign signs ad-hoc inside-out.
# Video runtime (M5.T01, P-media-11; D-026 adopts M6.T16's signer + runtimes.yaml): python-build-standalone + hash-locked
# wheels + vendored FastVideo + antichat_video + our launcher → build/runtimes/video-runtime-<ver>.zip.
# CHECK=1 only checks the lock is current; SIGN=1 also signs (tools/runtime/sign_video_runtime.sh → build/runtimes/signed/,
# catalog/runtimes.yaml sha256/size, site/public/runtimes/ for `make site-dev`).
runtime-video:
	python3 -I tools/runtime/build_video_runtime.py $(if $(filter 1,$(CHECK)),--check-lock) $(ARGS)
	@if [ "$(SIGN)" = 1 ] && [ "$(CHECK)" != 1 ]; then SIGNING_MODE=$(SIGNING_MODE) tools/runtime/sign_video_runtime.sh; fi

# M5.T02 task check: the runtime's pytest suite inside the runtime interpreter (pytest from a side --target install,
# never shipped). REAL=1 adds the @realModels legs (GPU: wrapped in gpu-run.sh shared).
runtime-video-test:
	@test -x build/runtimes/video-test-site/pytest || [ -d build/runtimes/video-test-site/_pytest ] || \
	  uv pip install --python build/runtimes/video-runtime/bin/python3.12 --target build/runtimes/video-test-site pytest==8.4.2
	ANTICHAT_VIDEO_TEST_SITE=$(CURDIR)/build/runtimes/video-test-site $(if $(filter 1,$(REAL)),ANTICHAT_REAL_MODELS=1 $(HOME)/AntiChat-tools/gpu-run.sh shared --) \
	  build/runtimes/video-runtime/bin/video-runtime-launcher --pytest -s Packages/Engines/Python/tests/test_generator.py $(ARGS)

# File tools runtime (M6.T15, P-files-tools-09): Python-Apple-support 3.13-b18 (sha256-pinned) + hash-locked wheels
# → build/runtimes/filetools-runtime-<ver>.zip (deterministic) + manifest + build/at/AT-018/<date>/size.json.
# CHECK=1 verifies only (base hash, lock current, uv pip sync --require-hashes, zip vs manifest); LOCK=1 re-locks.
# SIGN=1 (M6.T16) also signs it (tools/release/sign-runtime.sh, python.entitlements; SIGNING_MODE) into
# build/runtimes/signed/, updates catalog/runtimes.yaml and copies the zip to site/public/runtimes/ (make site-dev).
RT_FT_ZIP = filetools-runtime-0.1.0.zip
runtime-filetools:
	Runtimes/filetools-runtime/build.sh $(if $(filter 1,$(CHECK)),--check) $(if $(filter 1,$(LOCK)),--lock) $(ARGS)
	@if [ "$(SIGN)" = 1 ]; then mkdir -p build/runtimes/signed site/public/runtimes && \
	  tools/release/sign-runtime.sh build/runtimes/$(RT_FT_ZIP) Runtimes/filetools-runtime/entitlements/python.entitlements \
	    --mode $(SIGNING_MODE) --out build/runtimes/signed/$(RT_FT_ZIP) --report build/at/AT-018/$$(date -u +%F)/signing.log \
	    --update-catalog catalog/runtimes.yaml --name filetools-runtime && \
	  cp build/runtimes/signed/$(RT_FT_ZIP) site/public/runtimes/$(RT_FT_ZIP); fi

bootstrap:
	tools/bootstrap.sh $(ARGS)

pins-verify: ; python3 -I tools/ci/pins-verify.py

binaries:
	$(ENV) CHECK=$(CHECK) tools/binaries/build.sh

# Deterministic tiny models (environment.md §5); CHECK=1 only verifies against the lock.
stub-models:
	$(ENV) $(PY) -I tools/fixtures/make-tiny-mlx.py --fixtures $(FIXTURES)
	$(ENV) $(PY) -I tools/fixtures/make-tiny-gguf.py --fixtures $(FIXTURES)
	$(ENV) $(PY) -I tools/fixtures/make-tiny-embed.py --fixtures $(FIXTURES)
	@if [ "$(CHECK)" = 1 ] || [ -f $(FIXTURES)/stub-models.lock.json ]; then \
	  python3 -I tools/fixtures/lock.py check $(FIXTURES)/stub-models $(FIXTURES)/stub-models.lock.json; \
	else \
	  python3 -I tools/fixtures/lock.py write $(FIXTURES)/stub-models $(FIXTURES)/stub-models.lock.json; \
	fi

# Dev models (M1 convention 4; since M2.T12 the content-addressed store, A-M2-T10a (d)): the set's ids come from
# catalog/dev.yaml → catalog/dev-catalog.json (TIER=min|T0|T1|T3|evil-T1); `antichat-cli models import` first reuses
# matching files already on disk (pre-M2 `<Models>/<key>` dirs, APFS clones, sha256-checked), then `models install`
# downloads whatever is still missing (anonymous HF through NetworkGate, verified) and materialises
# `<Models>/installs/<id>`, which the benches and test-integration-real read. MANIFEST=m0 (the M0 image/video spike
# sets, no 1:1 catalog id) still uses tools/dev/hf-fetch.py and the old layout.
ANTICHAT_CLI = swift run --disable-keychain --force-resolved-versions -q antichat-cli
DEV_MODELS = $(if $(ANTICHAT_DEV_CACHE),$(ANTICHAT_DEV_CACHE)/Models,$(HOME)/Library/Application Support/AntiChat-Dev/Models)
dev-catalog:
	$(PY) -I tools/dev/gen-dev-catalog.py
models-dev:
	@if [ "$(MANIFEST)" = m0 ]; then python3 -I tools/dev/hf-fetch.py --set $(TIER); \
	else $(PY) -I tools/dev/gen-dev-catalog.py --check && \
	  ids=$$(python3 -I -c 'import json,sys; print(" ".join("--id " + k for k in json.load(open("catalog/dev-catalog.json"))["sets"][sys.argv[1]]))' $(TIER)) && \
	  { $(ANTICHAT_CLI) models import --models "$(DEV_MODELS)" --from "$(DEV_MODELS)" $$ids || true; } && \
	  $(ANTICHAT_CLI) models install --models "$(DEV_MODELS)" $$ids; fi

models-clean:
	rm -rf "$${ANTICHAT_DEV_CACHE:+$$ANTICHAT_DEV_CACHE/Models}" "$(HOME)/Library/Application Support/AntiChat-Dev/Models"

# XcodeGen names the root package's folder reference after the checkout directory (a worktree's name churns the
# pbxproj), so it runs through a symlink named AntiChat; paths inside stay relative to the repo root. Deterministic
# hashing pins the order of the two same-named "Embed Dependencies" phases (else their object ids swap per run).
xcodeproj:
	$(ENV) d=$$(mktemp -d) && ln -s "$(ROOT)" "$$d/AntiChat" && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate --spec "$$d/AntiChat/project.yml"; rc=$$?; rm -rf "$$d"; exit $$rc

# Restage build/binaries/* from the build cache when they differ from Binaries/checksums.json (never ship a stale
# helper binary); fails with "run make binaries" when no matching build exists. The Copy Helpers phase re-verifies.
stage-binaries: ; tools/binaries/stage.sh

build: stage-binaries
	$(ENV) set -o pipefail && xcodebuild -workspace AntiChat.xcworkspace -scheme AntiChat-Debug -configuration Debug \
	  -derivedDataPath build/dd -disableAutomaticPackageResolution -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=- build | $(BEAUTIFY)
	rm -rf build/AntiChat.app && cp -R build/dd/Build/Products/Debug/AntiChat.app build/AntiChat.app

# Release build + inside-out signing (M0.T12, ci-release.md §3). ARCHS=arm64 for every target (Apple silicon only;
# SwiftPM targets otherwise also build x86_64 in Release, where sqlite-vec's NEON path does not compile). SIGNING_MODE=adhoc|dev|devid (default adhoc;
# devid needs the Developer ID identity, D-017/Q-003). Xcode does not sign (CODE_SIGNING_ALLOWED=NO); the
# post-build "Copy Helpers" phase embeds build/binaries/{llama-server,sd-server,sd-cli}; sign.sh signs everything.
SIGNING_MODE ?= adhoc
APP_VERSION ?= $(shell sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml | head -n 1)
# RELEASE_CDEFS: Xcode's Release config does not define NDEBUG for SwiftPM C/C++ targets; DuckDB's D_ASSERT then
# falls back to <assert.h> on variables that only exist under DEBUG (row_group_collection.cpp `source_offset`).
RELEASE_CDEFS = GCC_PREPROCESSOR_DEFINITIONS='$$(inherited) NDEBUG=1'
# The release antichat-bench (perf/soak/AT benches): SwiftPM's release config does not define NDEBUG for C/C++
# targets either, so pass it like RELEASE_CDEFS (DuckDB D_ASSERT, A-M6-T10a (g)). Output: .build/release/antichat-bench.
BENCH_CDEFS = -Xcc -DNDEBUG -Xcxx -DNDEBUG
bench-release:
	swift build -c release --disable-keychain --product antichat-bench $(BENCH_CDEFS)
# M10.T01: tools/release/build-release.sh = xcodebuild archive (same flags) → build/release/AntiChat.app (arm64
# slices only, version stamped: APP_VERSION, CFBundleVersion = commit count; dSYMs beside it) → sign.sh →
# verify-signing.sh → devid: notarize + staple + Gatekeeper check (NOTARIZE=0 skips; then labelled UNNOTARIZED).
# The built app is never launched: it carries the shipped bundle ids under this build's signature (M10 card).
# M9.T05: optimized perf-harness app (Release -O/NDEBUG + ANTICHAT_PERF_HARNESS test hooks) → build/perf-app/AntiChat.app;
# never shipped (tools/ci/perfharness-guard.py). make perf-all measures with it.
build-perf: stage-binaries
	tools/perf/build-perf.sh
build-release: stage-binaries
	SIGNING_MODE=$(SIGNING_MODE) APP_VERSION=$(APP_VERSION) ANTICHAT_ALLOW_DEV_KEYS=$(ANTICHAT_ALLOW_DEV_KEYS) tools/release/build-release.sh
# Owner try-out preview, never a release (tools/ci/tryout-guard.py): every pack on (ANTICHAT_TRYOUT_PREVIEW) and the
# signed runtime zips from TRYOUT_RUNTIMES bundled (sha256 = catalog), ad-hoc signed, dev keys → build/tryout/.
TRYOUT_RUNTIMES ?= build/runtimes/signed
build-tryout: stage-binaries
	TRYOUT_PREVIEW=1 OUT=build/tryout TRYOUT_RUNTIMES=$(TRYOUT_RUNTIMES) SIGNING_MODE=adhoc ANTICHAT_ALLOW_DEV_KEYS=1 APP_VERSION=$(APP_VERSION) tools/release/build-release.sh
# Re-sign / re-verify / notarize the existing build/release artefacts (TARGET=app|dmg).
sign:
	tools/release/sign.sh --mode $(SIGNING_MODE) --app build/release/AntiChat.app --report build/release/sign-report.tsv
verify-signing:
	tools/release/verify-signing.sh --mode $(SIGNING_MODE) --out build/release/verify build/release/AntiChat.app
notarize:
	tools/release/notarize.sh --mode $(SIGNING_MODE) --out build/release/notary \
	  $(if $(filter dmg,$(TARGET)),--dmg build/release/AntiChat-Installer-$(APP_VERSION).dmg,--app build/release/AntiChat.app)
# M10.T02: DMG (dmgbuild, no Finder scripting) → sign (dev/devid) → NFR-D1 gate → devid: notarize + staple →
# verify-dmg.sh. Background art: build/release-venv/bin/python -I tools/release/dmg/make-background.py.
dmg:
	tools/release/package-dmg.sh
# M10.T03: Sparkle feed (FEED=dev|stable) → site/public/appcast[-dev].xml, signed + linted; nothing is published.
FEED ?= dev
appcast:
	FEED=$(FEED) tools/release/appcast.sh
# Release tooling self-tests (appcast-post, pr5-check, release-lint, site hosting-check + serve-site), stdlib + pytest in a throwaway env.
test-release-tools:
	uv run -q --no-project --with pytest==8.4.2 python -I -m pytest tools/release/tests tools/site/tests tools/ci/tests/test_release_lint.py -q -p no:cacheprovider
# Publish preflight (M10 card): every blocker between the local artefacts and a public release; exit 0 = none.
release-preflight:
	python3 -I tools/release/preflight.py

# make test-unit [FILTER=<TestSuite>] (docs/prd/M1.md convention 3). Without FILTER also the ChildSafetyCheck package.
# M2.T02: FILTER=A,B,C expands to one regex '(^|\.|/)(A|B|C)(\.|/|$$)' (suites, nested suites such as
# WindowSuites/X, or test targets; a single name stays a raw --filter string); a filtered run that executes 0 tests
# fails (a mistyped filter never passes vacuously).
# tools/ci/test-unit.sh fails the run on a non-zero exit, a failure in the console or xUnit report, or a Swift Testing
# run without its summary (a test process that exited 0 early); `make test-unit-selftest` proves it catches both.
comma := ,
FILTER_RX = $(if $(findstring $(comma),$(FILTER)),(^|\.|/)($(subst $(comma),|,$(FILTER)))(\.|/|$$),$(FILTER))
# A-M9-T05-AT282b: the forced aligner behind AT-282 AC2 (BargeInFixtureTests); pinned, idempotent, ~1.4 GB outside the repo.
mfa: ; tools/voice/setup-mfa.sh
test-unit:
	tools/ci/test-unit.sh '$(FILTER_RX)'
test-unit-selftest:
	tools/ci/test-unit.sh --selftest

# ---- M1.T02: audits, test runners, perf/bench/visual entry points (environment.md §8 semantics) ----
# R-241 + module graph + forbidden deps + patch-lint + copy-sync + URLSession lint + licence scan (tools/ci/audit.sh).
audit:
	tools/ci/audit.sh
# Negative self-tests: each audit must fail on its seeded violation.
audit-selftest:
	$(PY) -I -m pytest tools/ci/tests -q -p no:cacheprovider

# CONFIG=Release runs the hosted suites against a Release build (own derived data). Hosting makes Xcode link the
# package products shared by app and test bundle as dynamic frameworks, which xcodebuild signs ad-hoc without
# tools/release/sign.sh's library-validation exemption, so under the hardened runtime dyld rejects them at launch
# ("Library missing", A-M1-T14c). The shipped app links them statically and is unaffected; test runs drop the
# hardened runtime instead.
XCTEST_CONFIG = $(if $(filter Release,$(CONFIG)),-configuration Release ENABLE_HARDENED_RUNTIME=NO ARCHS=arm64 $(RELEASE_CDEFS) -derivedDataPath build/dd-rel,-derivedDataPath build/dd)
XCTEST = xcodebuild test -workspace AntiChat.xcworkspace -destination 'platform=macOS,arch=arm64' \
  $(XCTEST_CONFIG) -disableAutomaticPackageResolution -packageAuthorizationProvider netrc CODE_SIGN_IDENTITY=-
ONLY = $(foreach f,$(subst $(comma), ,$(FILTER)),-only-testing:$(1)/$(f))  # M2.T02: FILTER=A,B → one per item
# Hosted suites build the app first (`make build`, same derived data) so they never compile against stale package
# modules left in build/dd by an earlier run; CONFIG=Release uses its own derived data and only stages binaries.
XCTEST_PRE = $(if $(filter Release,$(CONFIG)),stage-binaries,build) filetools-runtime-ready tools-venv
# M6.T19 gate hygiene: the hosted File tools suites need the signed runtime zip of catalog/runtimes.yaml (built and
# sha-checked here, never skipped) and tools/.venv (office-style-diff, fixture generators; bootstrapped here).
filetools-runtime-ready:
	tools/ci/filetools-runtime-ready.sh
tools-venv:
	@[ -x tools/.venv/bin/python3 ] || (cd tools && uv sync --frozen)
	@tools/.venv/bin/python3 -I -c "import openpyxl, docx, pptx" || { echo "tools-venv: tools/.venv lacks openpyxl/python-docx/python-pptx (cd tools && uv sync --frozen)"; exit 1; }
# Integration (stub): XPC helper + tiny models + ScriptedEngine. Env reaches the hosted tests via TEST_RUNNER_*.
# M8.T11 (R-226, NFR-D7): make test-install CASE=<remove-everything|uninstall|reinstall|…|all>[,<case>…] ENV=<tart|user|dev>
# (tools/install-test/run.sh; exit 3 = not run in this environment, logs in build/at/AT-226/ and build/at/AT-NFR-D7/).
test-install:
	CASE=$(CASE) ENV=$(ENV) tools/install-test/run.sh
# M10.T09: the final acceptance suite AT-FA-01…14 (runbook tools/release/final-acceptance.md): fresh Tart clones of
# antichat-clean-26.x (debug + release passes) + the host legs (AT-FA-06/08). Needs `make build` (the test-flavoured
# build) and the N-1/N DMGs for PASS=release. PASS=all|debug|release|host  LEGS=02,04,…  FORM=dev|devid
# PREV_DMG=… DMG=…  Evidence build/at/AT-FA-<nn>/<date>/, table build/at/AT-FA/<date>/summary.md.
test-final:
	PASS=$(PASS) LEGS=$(LEGS) FORM=$(FORM) PREV_DMG=$(PREV_DMG) DMG=$(DMG) tools/install-test/final-acceptance.sh
test-integration-stub: $(XCTEST_PRE)
	$(ENV) set -o pipefail && TEST_RUNNER_ANTICHAT_BACKGROUND=1 TEST_RUNNER_ANTICHAT_ENGINES=stub TEST_RUNNER_ANTICHAT_FIXTURES=$(FIXTURES) $(XCTEST) -scheme AntiChat-IntegrationTests $(call ONLY,AntiChatIntegrationTests) | $(BEAUTIFY)
# Integration (real): TIER=min|T0|T1|T3|evil-T1; fetches the tier's dev models first.
test-integration-real: $(XCTEST_PRE)
	$(MAKE) models-dev TIER=$(TIER)
	$(ENV) set -o pipefail && TEST_RUNNER_ANTICHAT_BACKGROUND=1 TEST_RUNNER_ANTICHAT_TIER=$(TIER) TEST_RUNNER_ANTICHAT_FIXTURES=$(FIXTURES) $(XCTEST) -scheme AntiChat-IntegrationTests $(call ONLY,AntiChatIntegrationTests) | $(BEAUTIFY)
test-ui: $(XCTEST_PRE)
	$(ENV) set -o pipefail && tools/ci/with-catalog-fixtures.sh tools/ci/with-mcp-ref.sh tools/ci/with-relay-dev.sh $(XCTEST) -scheme AntiChat-UITests $(call ONLY,AntiChatUITests) | $(BEAUTIFY)
# make perf METRIC=<NFR id without prefix> TIER=<T0..T4|T2-24|T3-48|na> [RUNS=20] → build/perf/report.json (C4/C1: DOC=<pdf> uses its text as the prompt, M6.T21)
# (M1.T26a, tools/perf/run.py; `python3 -I tools/perf/run.py --list` shows every metric and its probe). The Mac is
# shared: run.py records the machine load with every measurement and REFUSES (exit 3) when it is busy.
#   ALLOW_NOISY=1  measure anyway; the entry is marked quality=noisy, valid=false (never a gate or a baseline)
#   PERF_WAIT=<s>  wait up to s seconds for a quiet machine first      FROM_LOG=<jsonl>  ingest an ANTICHAT_PERF_LOG
#   PERF_REPLACE=1 overwrite an existing entry (default append-only)   OUT=<path>        another report file
# make perf-compare BASE=<git ref|file>: regressions vs a baseline (> 5 % S2, > 25 % on a ★ metric S1).
# make perf-targets [CHECK=1]: regenerate tools/perf/nfr_targets.json from nfr.md (CHECK=1: fail when stale).
RUNS ?= 20
PERF_TIER = $(if $(filter min,$(TIER)),na,$(TIER))
perf:
	python3 -I tools/perf/run.py --metric $(METRIC) --tier $(PERF_TIER) --runs $(RUNS) \
	  $(if $(FROM_LOG),--from-log '$(FROM_LOG)') $(if $(OUT),--out '$(OUT)') $(if $(MODEL),--model '$(MODEL)') $(if $(DOC),--doc '$(DOC)')
# M9.T05: every NFR probe + every deferred item in order (tools/perf/t05.py; plan docs/prd/M9-T05-runplan.md).
#   make perf-all                      T05 proper (quiet machine, gpu-run timing)   make perf-all LIST=1   the plan
#   make perf-all DRY=1 ALLOW_NOISY=1 [REDUCED=1]  dry run (cheap, gpu-run shared; REDUCED: no-GPU steps + 1 GPU probe per family)
#   STEPS=<ids|groups> SKIP_STEPS=<…> FROM_STEP=<id> U1_APP=<app> PERF_WAIT=<s per step, default 1800>
perf-all:
	python3 -I tools/perf/t05.py $(if $(LIST),list --md,run) $(if $(DRY),--dry) $(if $(REDUCED),--reduced) $(if $(ALLOW_NOISY),--allow-noisy) $(if $(OVERLAP),--overlap) \
	  $(if $(STEPS),--only '$(STEPS)') $(if $(SKIP_STEPS),--skip '$(SKIP_STEPS)') $(if $(FROM_STEP),--from '$(FROM_STEP)') $(if $(U1_APP),--u1-app '$(U1_APP)')
# M9.T06 AT-NFR-S3: the long mixed-session soak on the perf-harness app (make build-perf), real models, gpu-run shared:
#   make soak HOURS=8 TIER=T1    → build/at/AT-NFR-S3/<date>.json + memory.png    make soak MINUTES=20 → a dry run
# Extra options through ARGS (tools/perf/soak.sh --help): --images scripted, --skip <legs>, --app <AntiChat.app>.
soak:
	tools/perf/soak.sh --tier $(if $(filter min,$(TIER)),T1,$(TIER)) $(if $(MINUTES),--minutes $(MINUTES),--hours $(or $(HOURS),8)) $(ARGS)
perf-compare:
	python3 -I tools/perf/compare.py $(if $(wildcard $(BASE)),--baseline '$(BASE)',--baseline-ref '$(BASE)') \
	  --json build/perf/compare.json
perf-targets:
	python3 -I tools/perf/gen-targets.py $(if $(CHECK),--check)
# package-benchmark (P-shell-19) in the separate Benchmarks/ package.
bench:
	BENCHMARK_DISABLE_JEMALLOC=1 swift package --package-path Benchmarks --disable-keychain benchmark $(if $(FILTER),--filter '$(FILTER)')
# Offline/privacy runner (test-strategy §7); FILTER = case name, STEP = alias (M2.T03: offline-only | no-route |
# capture | incognito). Cases land with their tasks (M1.T20 first).
test-offline:
	@if [ -f tools/offline/run.py ]; then python3 -I tools/offline/run.py $(if $(or $(STEP),$(FILTER)),--case '$(or $(STEP),$(FILTER))'); \
	else echo "test-offline: no cases yet (first case: M1.T20 AT-090)"; exit 2; fi
# Visual QA queue for the computer-use QA agent (test-strategy §5): SCRIPTS="vq-01 vq-02".
VERSION ?= $(shell git describe --always --dirty 2>/dev/null || echo dev)
test-visual:
	mkdir -p build/visual/$(VERSION)
	printf '%s\n' $(SCRIPTS) > build/visual/$(VERSION)/queue.txt
	@echo "queued $$(wc -l < build/visual/$(VERSION)/queue.txt | tr -d ' ') runbook(s) → build/visual/$(VERSION)/queue.txt"
# Design tokens + copy catalog (M1.T03): tokens.md → AntiChatDesign/Tokens + Tokens.xcassets; copy-deck.md →
# App/AntiChat/Localizable.xcstrings + AntiChatDesign/Copy/CopyDeck.swift. Stdlib-only. CHECK=1 = fail if stale.
design-gen:
	python3 -I tools/design/gen-tokens.py $(if $(CHECK),--check)
	python3 -I tools/design/gen-xcstrings.py $(if $(CHECK),--check)
# Vendored npm dist files (M1.T09; upstream.md §2 row Vendor/js): npm ci --ignore-scripts from Vendor/js/package-lock.json
# into a temp dir, copy dist (mermaid.min.js → AntiChatUI/Resources/mermaid), refresh VENDORED.json. CHECK=1 = offline verify.
vendor-js:
	python3 -I tools/vendor/vendor-js.py $(if $(CHECK),--check)
	$(if $(CHECK),,tools/vendor-sync vendored-json)
# M6.T09: Noto fonts for the file-out renderers (pinned commits, sha256 in Vendor/fonts/vendored-fonts.json).
vendor-fonts:
	python3 -I tools/vendor/vendor-fonts.py $(if $(CHECK),--check)
	$(if $(CHECK),,tools/vendor-sync vendored-json)
run: build
	open build/AntiChat.app

fixtures:
	git -C fixtures lfs pull
	python3 -I tools/fixtures/lock.py check fixtures fixtures/fixtures.lock.json --exclude 'stub-models/*' --exclude 'stub-models.lock.json' --exclude 'downloads/*.bin'

# ---- M2.T04: signed model catalog (R-220, R-300; ci-release §6.3) ----
# make catalog: build (anonymous HF, pinned commits) → lint → sign (test key A until the M10 key ceremony) →
# schema/completeness check → publish to site/public/catalog/v2/ (+ immutable <version>.json) and the bundled
# baseline. Unchanged inputs keep the published version (byte-identical); any change publishes version + 1.
# make catalog CHECK=1: re-resolve every key against HF and diff catalog/catalog.lock.json (exit 1 on drift).
CATALOG_TOOL = swift run --disable-keychain --force-resolved-versions -q catalog-tool
CATALOG_KEY ?= $(FIXTURES)/catalog/test-keys/catalog-a.priv
CATALOG_SITE := site/public/catalog/v2
CATALOG_BASELINE := Packages/Platform/Sources/AntiChatPlatform/Resources/catalog-baseline.json
ifeq ($(CHECK),1)
catalog:
	$(CATALOG_TOOL) build --check
else
catalog:
	$(CATALOG_TOOL) build --out build/catalog/catalog.json
	$(CATALOG_TOOL) lint build/catalog/catalog.json
	$(CATALOG_TOOL) sign build/catalog/catalog.json --key-file $(CATALOG_KEY)
	python3 -I tools/ci/catalog-schema-check.py build/catalog/catalog.json --log build/at/AT-220/schema.log
	@v=$$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["catalog_version"])' build/catalog/catalog.json); \
	  mkdir -p $(CATALOG_SITE); \
	  if [ -f $(CATALOG_SITE)/$$v.json ] && ! cmp -s build/catalog/catalog.json $(CATALOG_SITE)/$$v.json; then \
	    echo "catalog: $(CATALOG_SITE)/$$v.json exists with other content (versions are immutable)"; exit 1; fi; \
	  cp build/catalog/catalog.json $(CATALOG_SITE)/catalog.json; cp build/catalog/catalog.json.sig $(CATALOG_SITE)/catalog.json.sig; \
	  cp build/catalog/catalog.json $(CATALOG_SITE)/$$v.json; cp build/catalog/catalog.json.sig $(CATALOG_SITE)/$$v.json.sig; \
	  cp build/catalog/catalog.json $(CATALOG_BASELINE); cp build/catalog/catalog.json.sig $(CATALOG_BASELINE).sig; \
	  echo "catalog: published version $$v → $(CATALOG_SITE)/ and the bundled baseline"
endif
# make skills-index: refresh the skills index the app ships (the bundled copy and the pins in tools/skills/
# overrides.json) from its sources' newest commits, validated first (tools/skills/refresh.py: the app's rules,
# counts, every skill file's size and hash). A refused run changes nothing. DRY=1: generate and validate only.
# Users do not wait for this: the app fetches the list from the public index repository, which runs the same
# refresh by itself every week (catalog/README.md; tools/skills/export-index-repo.sh copies the tooling there).
# The apps of Connections need no publishing: every install asks the relay (GET /v1/toolkits); the bundled curated
# snapshot is refreshed at release time with tools/composio/build-catalog.py.
SKILLS_WORK ?= $(or $(RUNNER_TEMP),$(TMPDIR),/tmp)/antichat-skills-index
skills-index:
	python3 -I tools/skills/refresh.py --work "$(SKILLS_WORK)" $(if $(DRY),,--apply)

# make catalog-fixtures: re-derive the signed fixture catalogs (fixtures/catalog/*.json) from the built catalog.
catalog-fixtures:
	$(CATALOG_TOOL) fixtures --from build/catalog/catalog.json --out $(FIXTURES)/catalog --key-file $(CATALOG_KEY)
# M10.T05 website (Starlight, static, no trackers): generated pages → astro build → security.txt + CSP headers →
# site-audit (PROD=1 also refuses placeholders) → vitest. Deploys are owner steps (docs/prd/M10-owner-steps.md):
# they need CONFIRM=owner and are never run by the build agents.
site:
	python3 -I tools/site/gen-pages.py
	python3 -I tools/site/legal-sync.py
	cd site && npm ci --no-audit --no-fund && npx astro build
	python3 -I tools/site/post-build.py site/dist
	python3 -I tools/site/site-audit.py site/dist $(if $(PROD),--prod)
	cd site && npx vitest run
# AT-304 legs on the built site (after `make site`; nothing is deployed): hosting-check.py over dist served on
# 127.0.0.1 with its vercel.json headers (--dev: the dev feed/runtime hosts are accepted; the deployed host is
# `hosting-check.py --url https://<host>`, an owner step) and the Playwright CSP check (pinned @playwright/test,
# headless Chromium, no network beyond localhost; every page 0 CSP violations, help search "disk" → FAQ).
site-test:
	python3 -I tools/site/hosting-check.py --dev --json build/site-test/hosting-check.json
	cd site && npx playwright test csp
VERCEL_PROJECT ?= antichat-site
site-deploy-preview site-deploy-prod: site
	@[ "$(CONFIRM)" = owner ] || { echo "$@: owner step only (docs/prd/M10-owner-steps.md); rerun with CONFIRM=owner"; exit 2; }
	@# The project by name (an unlinked dist/ would become a new project named "dist"); runtime zips are served from
	@# GitHub Releases, never from the site (site/public/runtimes/ is the `make site-dev` copy only).
	printf 'runtimes/\n.vercel/\n' > site/dist/.vercelignore
	cd site && npx --yes vercel@latest deploy $(if $(filter site-deploy-prod,$@),--prod) --cwd dist --project $(VERCEL_PROJECT) --create-if-missing --yes
# Local catalog host for Debug builds (Config/Endpoints.plist CatalogURL). Astro/Starlight arrives in M10.
site-dev:
	@if [ -f site/package.json ]; then npx --prefix site astro dev --port 4321; \
	else python3 -I -m http.server 4321 -d site/public; fi

# ---- M7.T10: Composio relay (relay/, architecture §8; M7.md §0.1 item 2) ----
# relay-dev: `vercel dev` when the Vercel CLI is logged in, else the no-login adapter scripts/local-server.ts on
# http://127.0.0.1:3000 (PORT overrides) with relay/.env.local, or relay/.env.test (mock Composio) when absent.
# RELAY_DEV_LOCAL=1 always takes the adapter (tools/ci/with-relay-dev.sh: the UI tests need the mock, never vercel dev).
relay-dev:
	@cd relay && { [ -d node_modules ] || npm ci --ignore-scripts; } && \
	if [ "$${RELAY_DEV_LOCAL:-}" != 1 ] && npx vercel whoami >/dev/null 2>&1; then npx vercel dev --listen $${PORT:-3000}; \
	else npx tsx scripts/local-server.ts; fi
relay-test:
	cd relay && npm ci --ignore-scripts && npm test
# AT-255 c1: no Composio credential in the app bundle (APP=<path> overrides).
bundle-secret-scan:
	python3 -I tools/ci/bundle-secret-scan.py $(or $(APP),build/AntiChat.app) --patterns tools/ci/secret-patterns.yml
