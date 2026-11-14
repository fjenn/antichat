# AntiChat — Master Plan v3 (research → PRD → build)

> Quality over everything. Every decision is grounded in evidence. Every deliverable is critiqued by someone other than its author before it counts as done. Nothing moves forward on an assumption that could have been checked.
> v3 = v2 + an adversarial review (its findings are folded in, marked [rev]).
> v4 = v3 + the user's method feedback (marked [v4]).

## The method in one paragraph [v4]
1. **Understand the reference products as users experience them.** A pure observation teardown of ChatGPT and Claude: no AntiChat thinking yet.
2. **Write the AntiChat vision.** The same product, with only the user's stated deltas.
3. **Map every building block it needs.**
4. **Find the foundation fork**, with its bundled engine, and the open-source pieces to glue on. Each candidate goes through **three research rounds:**
   - (a) breadth survey
   - (b) individual deep dive: docs, code, build it, run it, map its capabilities onto the vision
   - (c) independent re-verification of (b)
5. **Map the gaps and close each one** with reused open-source code, again in rounds.
6. **Compile all of it into a PRD and research packet** that a fresh agent can execute end to end with zero user input.

## Local-performance layer [v4]
ChatGPT and Claude hide all inference work in the cloud. AntiChat has to make local inference *feel* as fast and seamless on a consumer Mac. This is a first-class pillar of the product, not a tuning pass at the end.

**Approach: find, don't build** [v4b]. These problems are largely solved in existing open source (engines, schedulers, streaming stacks). The work is *research and selection*: find the components that already do this best, verify their claims from docs, code and published benchmarks, and choose ones that fit together. We do not run our own optimization experiments.

**Ownership across phases:**
- Phase 2 sets the felt-speed targets.
- Phase 3 makes it component `C-PERF`.
- Phases 4/5/9 research which engines, forks and components already deliver each optimization, and score it as a selection criterion.
- Phase 7 includes one light smoke check: the chosen stack hits the targets on this Mac when assembled.
- The PRD wires the chosen pieces in, plus a basic speed check in tests.

**Areas to research (three rounds each, open source first):**
- **Model format and quantization:** MLX vs GGUF, 4/5/6/8-bit, dynamic quants, per-tier choice.
- **KV cache:** quantized KV, prompt/prefix caching across turns and for system prompts, context reuse when editing or regenerating, sliding window and compaction.
- **Decoding speed:** speculative decoding / draft models, flash attention, batch prefill.
- **Model lifecycle:** keep-alive and warm loading, predictive pre-loading (e.g. load STT when the mic button is hovered), fast swap between Normal and Evil, unloading under memory pressure, and a scheduler for co-resident models (LLM + STT + TTS + image).
- **Apple hardware use:**
  - Unified-memory wired limits.
  - Metal GPU vs Neural Engine (Core ML/ANE for STT/TTS/VAD, to keep the GPU free for the LLM).
  - Efficiency vs performance core placement.
- **Streaming everywhere:** token streaming with smoothing, streaming TTS that starts speaking on the first sentence, streaming STT, progressive image previews.
- **Power and thermal:** a low-power mode on battery, thermal throttling awareness, background QoS, and yielding when other heavy apps run.
- **Disk and network:** chunked, resumable, parallel downloads with checksum verification; shared base weights between Normal/Evil variants where possible; deduplication.
- **Perceived speed:** instant UI on launch, a skeleton chat while the model loads, a fast small model first then a hand-off to the full one.

**Candidate open-source sources to evaluate** (not pre-chosen):
- MLX / mlx-lm / mlx-swift and its examples
- llama.cpp server/scheduler features
- Ollama's model scheduler
- LM Studio's open-source MLX engine
- WhisperKit / Core ML STT
- Streaming-TTS projects
- MLX image/video stacks

## Onboarding reference (user-provided) [v4]
- **Source:** 4 onboarding screenshots and a background artwork in `~/Desktop/onboarding packet`.
- **How it's used:** the 5 images are copied into `02-target/inputs/onboarding-reference/` and paired with a design note at `onboarding-reference.md`, describing structure, copy intent, tone and visual language.
- **Who sees them:** the user approved every agent, including the builder, seeing the images directly. The old brand name in them is ignored; the product is AntiChat. The artwork is reusable as a brand asset.
- **Its status:** a strong input for the onboarding flow in Phase 2, weighed alongside the ChatGPT/Claude first-run teardown and local-app onboarding.

**Observed flow:**
1. **Welcome:** dreamy landscape art, a big headline promise (owned, private, no accounts, full control, no restrictions), "Runs privately on your Mac", a single "Get started" button.
2. **Choose capabilities:** 4 glass cards (Chat = default and locked on; Voice, Images, Video toggles). Each card has an icon, a one-line verb ("Talk and write", "Speak and listen", "Make pictures", "Make clips") and a per-card download size. A hardware line shows chip, memory and free disk, with a total download size and Continue.
3. **Evil Mode:** its own screen, with a red-tinted mood shift, a big title, the one-liner "An AI that never says no", an explanation, a toggle, and a hardware-eligibility note.
4. **Preparing your AI:** per-pack progress bars ending in "Ready". Chat opens while the others finish. A "Ready for your Mac" card shows chip, memory, disk and badges. Reassurance copy: "models stay on this Mac; change later in Settings → Capabilities".

Throughout: a step counter (1/4…), a Back button, and the brand top-left.

**Lessons to carry into the spec:**
- The download sizes and the hardware-eligibility check must be accurate. In the screenshots, sizes show 0.0 GB and Evil Mode claims a 128 GB M5 Max has too little memory.
- The Evil-mode copy must not promise "zero restrictions", because the hard floor exists. Adult content is in; minors and non-consensual imagery of real people are out.
- Evil Mode needs an age/consent confirmation step.

## Upstream separation [v4]
Upstream separation is a core architectural rule, not an afterthought.
- **The fork:** tracked as an `upstream` git remote. Our code lives in our own modules/targets. Changes inside upstream files are minimal hooks, each listed in `UPSTREAM_PATCHES.md`. Pulling upstream improvements is a scheduled, scripted merge.
- **Components taken from other projects:** consumed as pinned dependencies (SwiftPM/npm/cargo package or git submodule), never pasted into our tree, wherever possible. When copying is unavoidable, the code goes into `vendor/<name>/` with its origin repo@commit recorded, plus a sync script.
- **Automation:** Renovate/Dependabot-style automated update PRs and a scheduled upstream-sync CI job with tests, so updates are routine, not painful merges.
- **How much separation is worth it:** this is a selection criterion for the fork and for every component, and it's proven in a spike before the PRD.

## 0. Context and target outcome
AntiChat is a free, open-source, account-free macOS (Apple Silicon) app. A consumer downloads a DMG, opens it, and within minutes has an experience indistinguishable from ChatGPT/Claude, except that it runs on local models. It is private, free, and offers an unrestricted "Evil mode".

**End state of this plan:**
1. A research packet in which every claim is cited.
2. A PRD that has been checked by adversarial review and de-risked by spikes, precise enough that I and my agents can build the whole product in one continuous run.
3. The built product: a signed, notarized DMG that passes the end-to-end acceptance suite and the user's dogfood session.

**Fixed product decisions** (the user's; not to be re-litigated):
- **Local-first.** Fully usable offline. Optional cloud features (web search, connectors) can be toggled.
- **Four packs:**
  - Text/Chat (on by default)
  - Voice (dictation + spoken conversation)
  - Photo generation
  - Video generation
- **Two modes per pack:** Normal and Evil (abliterated, near-0% refusal).
- **One chat window** for everything.
- **Models auto-selected** per Mac, with an advanced override. A pack is only offered at a quality level the Mac can run.
- **Distribution:** a signed, notarized DMG from the AntiChat website, with auto-update. No App Store. License is not a selection criterion. Redistribution terms matter only where we mirror weights. [rev]
- **Hard floor in all modes:** no sexual content involving minors, and no non-consensual sexual imagery of real people.

**Dev machine:** M5 Max, 128 GB, macOS 26.6, Xcode 27.1, ~995 GB free.

## 1. Quality system (applies to every phase)

### 1.1 Evidence standard
- **Every factual claim carries a source:** a URL plus access date, a screenshot or recording path, a benchmark result file, or a code reference (repo@commit:path:line). Unsourced claims are marked `[INFERENCE]` or `[ASSUMPTION]`, and each assumption has an owner phase that has to resolve it.
- **Confidence tags:** High (primary source, or observed/measured), Medium (secondary source), Low (single weak source). A decision that rests on Low evidence is re-verified or flagged at a gate.
- **Precedence:** observed beats documented, which beats third-party. Measured on target hardware beats published numbers.

### 1.2 Traceability
**IDs:**

| ID | Thing |
|---|---|
| `F-###` | Reference element/flow (elements and flows only; strings live in the copy deck) [rev] |
| `R-###` | Requirement |
| `C-###` | Component |
| `K-###` | Risk/unknown |
| `S-###` | Spike |
| `G-###` | Gap |
| `P-###` | Patch source |
| `M#.T#` | Milestone task |
| `AT-###` | Acceptance test |
| `B-###` | Bug |

**Machine-readable registries** live in `docs/research/registry/*.json`. The prose docs reference IDs; they don't duplicate the data. [rev]

`tools/trace-check.py` fails on any orphan. The chain must hold:
- every F has a verdict
- every P0/P1 R has a C and an AT
- every G has a P
- every K is closed or explicitly accepted

### 1.3 Deliverable lifecycle
1. **Rubric first:** with pass thresholds, written before the work.
2. **Draft** to the evidence standard.
3. **Self-critique** against the rubric, then fix.
4. **Independent review:** a fresh agent sees only the deliverable, its sources and the rubric. It scores the work, lists defects and tries to falsify key claims.
5. **Blind re-derivation** only for *major* decisions [rev]: runtime, fork, the per-pack model choices, and L/XL gaps. A second agent reaches its own answer from the same inputs. When my answer and the blind answer disagree, I re-research until the evidence explains the difference.
6. **Reconcile** in `REVIEW-LOG.md`: every defect is fixed, or rejected with a written reason. Done only when the rubric passes and the log is closed.

### 1.4 Continuity (long unattended runs) [rev]
- **`STATUS.md`** holds the current step, what's done and next, blockers, and the last commit. It's updated after every step.
- **Per-phase `DIGEST.md`** is capped at about 150 lines. It's the only thing later phases read by default; details are pulled by ID with grep or the registry.
- **Logs:** `DECISIONS.md` (ADRs), `QUESTIONS.md` (batched to gates; non-blocking questions run on a documented default), `REVIEW-LOG.md`.
- **One git commit per completed step.**

### 1.5 Agent orchestration
- **Self-contained briefs:** every subagent brief states the goal, inputs (packet paths/IDs), output path and format, the rubric, what's out of scope, and "cite everything". Reviewers and blind agents never hear my hypothesis.
- **Fan-outs** of 3–6 agents for independent research. Computer use is serial and done by me.
- **I spot-check at least 20% of subagent citations** before synthesizing. A subagent's report counts as a claim, not a fact.
- **Subjective judging:** text quality is judged by Claude subagents with a fixed rubric and blind pairwise comparison. Audio, image and video are shortlisted by automated metrics, and the user may make the final pick in an optional blind A/B session; otherwise the scores decide. [v4]

### 1.6 Timeboxes and stop rules [rev]
- **Every research step has a timebox** and a saturation rule: stop when a full extra pass yields fewer than about 3 new significant findings.
- **Overruns** are logged in STATUS along with the reason. Quality wins over the timebox only with a written justification.

### 1.7 Build-time change control [rev]
- **`PRD-AMENDMENTS.md`:** every deviation from the PRD during the build is recorded (what, why, evidence, impact).
- **Minor (amend and continue):** implementation detail, swapping in an equivalent library, or a task reorder that changes no requirement or user-visible behaviour.
- **Major (stop at the next gate or ask):** changing an R, the UX, a model, the fork, or an NFR budget, or a milestone failing its ATs after 3 fix attempts.
- **Every PRD task lists** its known failure modes and its fallback, not only its rollback.

### 1.8 Safety and consent
- **Reference accounts are read-only:** I only look, screenshot and send harmless prompts, and I revert any setting I touch. No deletes, no billing or account changes.
- **Downloads need consent:** each batch of clones or model downloads is listed in chat (names, sources, sizes) and waits for a yes. Clones go to `~/AntiChat/_vendor-eval/`, isolated.
- **Spending money** (EC2 Mac rental, domains, hosting) needs explicit confirmation of the item and cost.
- **Credentials and signing identity are the user's;** I give exact commands.

## 2. Gates (the only places I stop on purpose)

| Gate | When | User decides |
|---|---|---|
| **G0** | End of Phase 0 | Consent bundle: download budget, fresh macOS user for first-run tests, Developer ID/notarytool setup now, everything the build will need later (so the build never stops for you); optional low-RAM Mac access |
| **G1** | After Phase 2 | The AntiChat vision/spec |
| **G3** | After Phase 11 | The PRD + packet; after this the build runs autonomously |

[v4] Fork, engine and model choices are made by me and reported with evidence, not gated. An optional ~15-minute blind A/B listening/viewing session is offered for voice, image and video. If you skip it, I decide on automated scores. The final dogfood session is optional and comes after the build is complete; it never interrupts the build.

## 3. Phases

### Phase 0 — Foundation
- **Scaffold:**
  - `docs/research/` with README, STATUS, DECISIONS, QUESTIONS, REVIEW-LOG, GLOSSARY, `registry/`, `rubrics/`
  - Phase folders
  - `docs/PRD.md`
- **Tools:**
  - `tools/trace-check.py`
  - `tools/shot.sh`: per-window `screencapture -l`, auto-named
  - `tools/rec.sh`: 60 fps screen recording
  - `tools/frametime.py`: ffmpeg frame-diff extracts animation, streaming and transition timings from recordings [rev]
- **Rubrics** for every deliverable, each reviewed once.
- **Doc inventory:** write the two `documented-features.md` files from the completed doc-research notes, flagged Medium confidence for ChatGPT. Retry the official ChatGPT help pages via Chrome if it's connected. This becomes Phase 1's coverage checklist.
- **G0.**

### Phase 1 — Reference teardown (ChatGPT, Claude) — timeboxed, saturation stop
**Surfaces:**
- **Deep:** ChatGPT's new desktop app and Claude's desktop app, at element, state and flow level.
- **Diff-only:** ChatGPT Classic, plus OpenAI's and Anthropic's own websites (chatgpt.com, claude.ai), recording only what differs from the desktop apps. [rev] The websites are driven through the Chrome MCP, since browsers are read-only under computer use.
- **Pure observation:** no AntiChat verdicts are made during this phase. IDs are only catalogue labels. [v4]

**Method:**
1. **Crawl plan:** written per app from the coverage checklist, ordered by persona-journey importance.
2. **Per element:** location, purpose, default and all states, keyboard access, where it leads, tier gate, screenshot. Verbatim UI copy goes to the copy-reference file.
3. **Flows, each run end to end** with a 60 fps recording and step screenshots:
   - Text with thinking
   - File/image attach and vision
   - Image generation and editing
   - Dictation
   - Voice conversation
   - Web search
   - Deep research
   - Writing blocks/artifacts
   - Memory
   - Projects
   - Temporary/incognito chat
   - Share/export
   - Quick Chat / Quick Entry
   - Settings (each change reverted)
   - Data export (the format matters for our importer) [rev]
4. **Interaction specs as rules,** not cloud latencies [rev]:
   - Streaming chunk smoothing and cadence (from frame timing; on the web, also SSE timing and CSS transition values via DevTools)
   - Auto-scroll lock
   - Stop/interrupt semantics
   - Composer behaviour (multi-line, paste, drag-drop, large-paste-to-attachment)
   - Error recovery
   - Long-chat behaviour
   - VoiceOver labels on key controls
5. **First-run:** in a fresh macOS user, if granted at G0. Otherwise from the docs, marked Medium.
6. **Reconcile docs against observation;** every conflict gets a resolution. Paid or region-gated features are taken from docs, marked as such.

**Local-app UX references** (only the flows ChatGPT/Claude lack: model download, hardware limits, disk, quality tiers, image/video generation UX):
- Quick survey, then the top 4–6 apps with consent to install, e.g. LM Studio, Jan, Msty, Ollama app, Draw Things.
- 1 session each, timeboxed.

**Outputs:**
- `01-reference/{chatgpt,claude}/{screen-catalog.md, flows/, screens/}`
- `copy-reference.md`
- `local-apps/`
- `registry/features.json`
- `ux-principles.md`: each principle tied to F-IDs
- `interaction-specs.md`
- `DIGEST.md`

**Review:** an independent agent gets the checklist and the screenshots and hunts for missing elements and states. It must find fewer than 3 significant misses; otherwise there's another fill-in round.

### Phase 2 — Define AntiChat
1. **Users and journeys:**
   - 4 personas: non-technical first-timer, privacy-minded professional, power user, unrestricted-use seeker.
   - Their jobs-to-be-done.
   - Journeys from hearing about it through website, download, first message, enabling more packs and daily use, all the way to uninstall.
2. **A verdict for every F**, with reasoning:
   - Keep: same UX, local backend
   - Adapt: a local equivalent, specified
   - Drop: accounts, billing, teams, cloud-only
   - Defer: a later version, with a reason
3. **Local-native requirements (R-###)**, a mandatory checklist [rev]:
   - **Hardware detection and tiers;** minimum macOS version decided early.
   - **Pack enablement** and the onboarding screens.
   - **Fast first chat:** a small model gets you chatting in under about 2 minutes while the better model downloads in the background. Default download size per tier.
   - **Downloads:** free-disk check, pause/resume/verify, and flaky-network behaviour.
   - **Disk dashboard;** remove all models/data; documented paths; uninstall.
   - **Model memory:** memory-pressure orchestration across loaded models; yielding to other heavy apps; thermal, battery and low-power behaviour.
   - **Recovery:** crash and stream recovery (autosave mid-generation, resume, clear messages when a model runs out of memory loading).
   - **Import** ChatGPT and Claude exports, plus full export of our own data.
   - **Offline guarantees**, and the optional cloud toggles (search, connectors).
   - **Evil mode UX:** placement (global vs per chat), visual state, activation disclaimer and age gate.
   - **Safety floor, specified as mechanisms** [rev]:
     - prompt classifier
     - output NSFW classifier plus age estimator
     - edit/img2img restrictions on real-face inputs combined with NSFW output
     - precision and recall targets on a test set built only from lawful proxies: adult NSFW detection, plus age estimation on non-sexual images
     - latency budget
   - **Legal/trust:** ToS, privacy statement, Evil-mode disclaimer, abuse/takedown contact. [rev]
   - **Diagnostics:** opt-in crash reporting, local log-bundle export, a "Report a bug" flow, zero telemetry by default. [rev]
   - **Updates:** app updates (Sparkle) separate from model-catalog updates (a signed manifest). [rev]
4. **Each R:** user story, acceptance criteria, priority (P0 = v1 must ship), and its source F or persona.
5. **Settings map / information architecture:** full tree, with defaults.
6. **NFRs as targets:** cold start, TTFT, tok/s floor, voice round-trip, image/video time, memory/disk budgets, stability, accessibility, privacy, security (sandboxing for code execution and MCP).
7. **ADR: distribution and hosting** [rev]:
   - model mirror/CDN with a checksummed, signed catalog
   - fallback if Hugging Face repos vanish
   - certificate-revocation contingency
   - redistribution terms of mirrored weights
   - naming and copy review for Evil mode
8. **Risk register K-###**, including legal exposure.

**Outputs:** `02-target/{personas, journeys, product-spec, requirements (+registry), settings-map, hardware-tiers (hypotheses), nfr, risks, adr-distribution}.md`, `DIGEST.md`

**Review:**
- A "consumer advocate" agent walks each journey and scores friction.
- A "scope critic" agent challenges the Keep/Drop verdicts.
- A "legal/safety" agent reviews the floor and distribution.

**→ G1.**

### Phase 3 — Components (provisional)
- **Split the Rs into C-### components** with interfaces, data flows, the Rs they serve, quality criteria, and open questions (K). [rev] Harness config is a first-class component: chat templates, sampling defaults, context-overflow strategy, thinking-mode handling, tool-calling, Evil system prompts.
- **System diagram.**
- **Refreshed after fork selection** against the fork's real seams.
- **Output:** `03-components/`

### Phase 4 — Engine landscape (input to fork selection, not a separate decision) [v4]
- **Survey the Apple Silicon engines** for each modality: MLX/mlx-swift, llama.cpp, Core ML, MLX image/video stacks, STT/TTS engines.
  - Most candidate forks already bundle one, so here the engine is evaluated as a *property of each fork*, and as "can this fork swap or add engines for the modalities it lacks?"
- **Three rounds:**
  1. Breadth.
  2. Deep dive per engine: docs, code, a short benchmark on representative models, formats, availability of abliterated variants.
  3. Independent re-verification.
- **Output:** an engine fact sheet that Phase 5 scores against.

### Phase 5 — Fork discovery and selection
1. **Long list:** parallel agents with different angles (GitHub topics/stars, awesome-lists, r/LocalLLaMA, HN, Product Hunt, "alternatives to"). Covers native, Tauri, Electron and web-wrapped apps, plus harness frameworks. At least 30 candidates.
2. **Rubric fixed before scoring,** with weights derived from P0 coverage. Runtime compatibility (Phase 4) is a hard filter. Criteria:
   - P0 coverage by R-ID
   - UX closeness to Phase 1
   - Multimodal extensibility
   - Seams for a separate layer, and how friendly it is to upstream merges
   - Code quality and tests
   - Upstream health (cadence, maintainers, issue response, bus factor)
   - Build/sign friction
   - Performance
3. **Paper screen** down to 5–8.
4. **Hands-on with 3–5,** with consent:
   - Clone at a pinned commit, build, and run the standard eval script (onboarding, chat, attach, vision, voice, image, model management, settings), with screenshots.
   - Map the architecture seams.
   - Estimate the gap size against the R-list.
5. **Blind second scorer.**
6. **ADR** with the winner, a "why not" for each runner-up, and a fallback fork.

**Output:** `05-fork/`

**Each candidate gets three rounds** [v4]:
1. Breadth.
2. Individual deep dive: docs, code, build, run, and a capability map against the vision.
3. Independent re-verification.

**→ Decision reported with evidence (no gate).** Then refresh Phase 3.

### Phase 6 — Models (on the chosen runtime) — evidence-based
**Survey:** per pack, Normal and Evil candidates, with formats, published evals, abliteration method and known quality cost, community standing, and redistribution terms.

**Evidence comes primarily from published sources** [v4b]: model cards, official and community benchmarks and leaderboards, the engine projects' own numbers. Our own measurements below are a *light confirmation on finalists only* (1–3 per pack × mode), not a research program. Wherever a reputable published number exists, it is used and cited instead of re-measuring.

**Harness:** `03-components/benchmarks/`, versioned scripts with results kept as files.

**Text benchmarks:**
- TTFT, tok/s, peak RSS per quant
- Public-benchmark subsets run locally
- AntiChat consumer-task set, judged blind and pairwise by subagents
- Tool-calling reliability (BFCL subset plus our own agentic tasks: search, memory, artifacts, MCP) [rev]
- Long-context and overflow behaviour [rev]
- Evil models: refusal rate on a standard refusal-benchmark subset, plus the quality delta against the base model

**Voice:**
- STT: WER on a standard set plus fixtures, RTF and latency
- TTS: time to first audio, UTMOS/DNSMOS proxy scores
- Full voice-conversation round-trip latency

**Image:** seconds per image, peak memory, CLIP/VQA-based prompt adherence on a fixed prompt set, and an edit check.

**Video:** seconds per clip, peak memory, VBench-subset proxies, feasibility per tier.

**Concurrency:** LLM+STT+TTS together, and LLM+image/video handoff.

**Tiers** [v4]:
- **Start from what the creators and distributors publish:** model card RAM/VRAM requirements, file sizes per quant, and recommended hardware.
- **Compute the expected footprint:** weights + KV cache at target context + runtime overhead, with headroom for macOS and other apps.
- **Verify on this Mac:** under memory caps, scaling speed by published memory-bandwidth ratios per chip.
- **Labelled best estimates are acceptable.** Real low-RAM hardware is a bonus, not a requirement.

**Selection per pack × mode × tier:** model, quant, runtime, and fallback, each with its evidence table. Blind re-derivation.

**Output:** `06-models/`

**→ Optional blind A/B session** for audio, image and video; if you skip it, automated scores decide. Decision reported, no gate. [v4]

### Phase 7 — Spikes (de-risk on the chosen fork, throwaway branches, timeboxed)
For every High-impact K still open. Expected:
1. Fork builds, signs and notarizes as AntiChat.
2. Our layer lives outside the upstream tree, and survives a *replay of the last N months of upstream commits*. [rev]
3. LLM runtime in the fork at target speed; harness config validated.
4. Voice round-trip within budget.
5. Image/video callable from chat, with memory handoff.
6. Normal/Evil swap.
7. Safety-floor classifier precision, recall and latency.
8. Fast-first-chat download path.
9. ChatGPT/Claude export import.

Each S-### records: question, method, result, evidence, and what it means for the PRD. A failed spike reopens the owning phase, documented.

### Phase 8 — Gap analysis
- **Rate every P0/P1 R** against the fork: Present, Partial, Missing, or Conflicting, with evidence (code ref or eval screenshot).
- **Deviations to remove or hide.**
- **For each G:** size, dependencies, risk.
- **Review:** an agent re-verifies at least 25% of the "Present" verdicts against the code and the running app.

### Phase 9 — Patch sourcing
- **Search per gap, in rounds** [v4] (find, deep-dive each candidate, independent re-verification):
  - L/XL gaps: three angles (libraries/packages; modules inside other open-source apps, including the runners-up; reference implementations).
  - S/M gaps: one focused search. [rev]
- **Hands-on evaluation** for non-trivial candidates.
- **Per P-###:** source@commit, integration (dependency / vendored / ported), the adapter we write, and alternatives rejected.
- **Custom code** requires a search log.
- **Review:** an agent hunts for better pieces for the 10 largest gaps and for every custom gap.

### Phase 10 — Architecture, upstream, design system, test strategy, environment
- **Repo:**
  - Upstream as a remote, our code in separate modules
  - `UPSTREAM_PATCHES.md`, minimal and justified
  - Sync procedure, already rehearsed in spike 2
- **Environment** [rev]:
  - `bootstrap.sh` and pinned toolchain (Xcode/Swift/Node), lockfiles
  - Fixtures repo: WAVs, golden images, prompt sets
  - Tiny stub models for fast tests
  - Model hosting setup per the distribution ADR
- **CI:** a self-hosted runner on this Mac for build, tests and model tests. Hosted CI only for clean-room signing/notarization, if useful. [rev]
- **Release:**
  - Sparkle appcast
  - Signed model catalog
  - Website with download, legal pages and privacy statement
  - Release checklist
- **Design system:**
  - Tokens, component specs and states, iconography, light/dark
  - Full copy deck
  - A *scored per-screen parity rubric* against the Phase 1 screenshots, with a pass bar [rev]
- **Test strategy:**
  - Unit, integration (stub and real models), UI tests for the fork's stack
  - Computer-use visual QA scripts
  - Performance regression
  - Offline, clean-machine install, upgrade, uninstall
- **Bug severity rules,** written now. Triage is done by an independent agent, not the builder. [rev]

### Phase 11 — PRD
**`docs/PRD.md`:**
- Summary, scope in/out, personas
- R-### with acceptance criteria
- NFR budgets (now measured)
- Model matrix
- Architecture, environment
- Design system and copy references
- Change control (§1.7)
- Milestones

**Each task `M#.T#` states:**
- Inputs, files/modules
- P-### sources
- Exact steps
- AT-### (commands plus a visual QA script)
- Definition of done
- Known failure modes and fallback
- Rollback

**Milestones:**
- **M0.** Environment, fork → AntiChat build, CI, signing skeleton, stub models
- **M1.** Shell, design system, chat (Text pack, Normal), harness config
- **M2.** Hardware tiers, onboarding, fast-first-chat, model manager, disk dashboard
- **M3.** Voice pack
- **M4.** Safety floor + Photo pack. The floor ships with or before any generative image. [rev]
- **M5.** Video pack
- **M6.** Evil mode across packs
- **M7.** Parity features: projects, memory, files/RAG, artifacts/writing blocks, search, connectors, Quick Chat, shortcuts, import/export
- **M8.** Recovery, diagnostics, uninstall, legal pages
- **M9.** Polish against the parity rubric; performance and stability hardening
- **M10.** Release: notarized DMG, appcast, model catalog, website

**Review:**
- An executability dry-run agent goes task by task and lists every ambiguity or missing input.
- A trace reviewer checks the chain.
- `trace-check.py` passes.

**→ G3.**

### Phase 12 — Build (execute the PRD)
- **Per milestone:**
  1. Implement and run the ATs.
  2. Launch the app.
  3. Computer-use visual QA, scored on the parity rubric.
  4. Check the NFR budgets.
  5. Independent code review (`/code-review` at high effort).
  6. Independent bug triage.
  7. Commit, then update STATUS and PRD progress.
- **Upstream sync rehearsal** after M3 and before M10.
- **Final acceptance** on a clean macOS user account:
  1. Download from the website; Gatekeeper passes.
  2. Onboarding.
  3. Fast first chat.
  4. Offline chat.
  5. Dictation and voice conversation.
  6. Image, then video.
  7. Evil mode.
  8. Safety floor fires.
  9. Import a ChatGPT export.
  10. Crash recovery.
  11. Relaunch keeps history.
  12. Appcast update.
  13. Uninstall cleans up.
  14. Low-RAM tier run, if hardware is available.
- **Ship at zero open P0/P1 bugs** and every milestone rubric passing.
- **Optional dogfood** after completion. The build itself never stops for user input. [v4]

## 4. Known risks to the plan
- **Computer use contention:** if the screen is busy, non-screen work continues and screen tasks queue.
- **No low-RAM hardware:** tier claims are labelled best estimates, built from what model creators publish plus measurements on this Mac.
- **Reference products change mid-run:** every observation is date-stamped.
- **Abliterated model quality may lag the base model:** this is measured, and fallbacks are defined.
- **Video may be infeasible on low tiers:** the pack is hidden there.
- **Plan rigidity:** a failed spike or gate legitimately reopens earlier phases. That's by design, not failure.
