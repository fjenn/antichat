# Build brief (every build agent reads this first; D-025)

Repo `~/AntiChat`, macOS SwiftUI app "AntiChat": a local ChatGPT clone. You build tasks from `docs/prd/M*.md`.

## Read
- This file, then ONLY your task sections in `docs/prd/M<n>.md` and the milestone card `docs/prd/M<n>-card.md` if it exists.
- For other docs (PRD.md, PRD-AMENDMENTS.md, research packet), grep by ID when a task references one. Don't read them whole.

## Rules
- Work on the branch/worktree you are given, tasks in the order given, one commit per task (`M<n>.T<k>: <title>` + trace IDs in the body).
- Always `make build` (`swift build` does not compile the app target). Then run the unit tests of the packages you touched. Run the full `make test-unit` once before your final commit, against **your worktree's own fixtures submodule** at the pinned commit (`git submodule update --init fixtures && git -C fixtures lfs pull`, then `ANTICHAT_FIXTURES=$PWD/fixtures`). Never use or commit in another checkout's fixtures (the shared `~/AntiChat/fixtures` is not a test input). Push fixture commits to the bare repo's main only after the code that needs them is on main.
- GPU/model runs: wrap them in `lockf /tmp/antichat-gpu.lock <cmd>`.
- Don't work around tool refusals; report them.
- Never open anything about any earlier product; this repo is the only source.
- Safety: the only filter in the product is `Packages/ChildSafetyCheck` (D-006). Add no other filtering.
- Flaky tests: if a test depends on timing, make it deterministic once, or delete it and say so. Don't loop on it.
- Paperwork: add a row to `docs/PRD-AMENDMENTS.md` only for a real deviation from the PRD. Skip STATUS, registries and review logs.
- Don't do the full NFR re-measurement or the screen-by-screen parity scoring (they belong to M9). Do run the task's ATs and its headline speed number.
- Fixtures submodule: push from inside it with `git -c protocol.file.allow=always push origin HEAD:refs/heads/<branch>`.

## Report back (≤ 15 lines)
For each task: done/blocked, the commit, the ATs run, and any amendment. Then anything the lead must decide.
