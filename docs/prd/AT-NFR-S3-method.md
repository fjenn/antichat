# AT-NFR-S3 method note: how the soak runs the app, and why

AT-NFR-S3 (M9.T06): `make soak HOURS=8 TIER=T1`. **Pass:** growth ≤ 10 %, 0 crashes, 0 main-thread hangs > 2 s. The
bar and the hang detector are unchanged by this note. It records how the app under test is launched and scheduled,
so that the soak measures the app a user runs.

## The detector

`App/AntiChat/SoakProbe.swift` `HangWatchdog`: a thread pings the main queue every 250 ms. A stall ≥ 250 ms is a
`hangs.jsonl` row; > 2 s fails the run (`tools/perf/soak-report.py`). Since r65 a stall ≥ 1 s also gets
`probe/hang-stacks/NNNN-<s>s-<phase>.txt`:
- the main thread sampled every 50 ms (call tree, like `sample`);
- every other thread once at 1 s;
- the load average and the busiest processes with their priorities.

The row records:
- `where`: the deepest app frame in most samples;
- `main_cpu_s`: the main thread's CPU during the stall;
- `main_states` and `main_pri`.

`main_cpu_s ≈ seconds` means the main thread was working. `main_cpu_s ≈ 0` with `running` states means it was
runnable but not scheduled (starved). `waiting` means it was blocked on something.

Sampling does not change the measurement:
- the stall still ends when the main queue runs the ping;
- a 300 ms CPU job under 24 busy loops took 0.33–0.36 s wall with sampling and 0.33–0.36 s without (one outlier each way).

## What the 8-h run's stalls were

The 8-h T1 run failed only on hangs: 40 > 2 s (max 4.37 s), 1,163 > 250 ms. Almost all fell in the streaming legs
(chat, normal, quickpanel), from 18 to 21Z, while the Mac was saturated by parallel builds and tests.

A 30-min loaded rerun with stacks (16 × `yes`, load average 1-min median 35.9, range 8.7–57.8) gave 3 stalls > 2 s and
128 > 250 ms. Every stall ≥ 1 s was the same picture:
- The main thread was `running` (runnable) in 100 % of samples.
- It got 0.07–0.41 s of CPU over 1.1–3.1 s, at priority 31 decaying to 11–25.
- It was inside ordinary SwiftUI work: `NSHostingView.beginTransaction` → graph update, `OpaqueFillLayout`, the
  MarkdownView text renderer and math preprocessor, a `ComposerTextView.makeNSView`.

That is 100–400 ms of CPU stretched into seconds by starvation. No sample was waiting on the database writer, a lock
or XPC.

## Why the main thread got 31

The soak runs the app as a background run (`BackgroundRun`: no Dock icon, windows concealed, never active, input
in-process), so it never takes the owner's focus. Until r65 a background run used activation policy `.prohibited` and
`soak.sh` exec'd the binary from the shell.

Main-thread priority measured on macOS 26.6 (18 CPUs) with a probe app (`ps -M` / `thread_info`):

| Launch | Policy | Windows | Main thread |
|---|---|---|---|
| LaunchServices `open -g` | `.regular` | visible / off-screen / minimised / alpha 0 / none | 46 |
| LaunchServices `open -g` | `.accessory` | visible / off-screen / minimised / alpha 0 / none | 46 |
| LaunchServices `open -g` | `.prohibited` | any | **31** |
| shell exec | `.regular` | off-screen / alpha 0 | 46 (visible: 47, and it **activated**) |
| shell exec | `.accessory` | none / visible | 46 (alpha 0: 47 and it **activated**) |
| shell exec | `.prohibited` | any | **31** |

- **Other apps:** Finder 46, Chrome 46, Messages 47 (Safari App-Napped: 4).
- **QoS doesn't help:** in a `.prohibited` app, `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE)` succeeds
  (qos 0x21) but the priority stays 31.
- **App Nap is not involved:** a `.prohibited` probe kept priority 31 and full CPU share after 2 min hidden, with or
  without a `.userInitiated` activity.
- **31 is enough on its own:** under 16 busy loops, a `.prohibited` probe's 20 ms main-thread jobs never waited
  > 41 ms. What starved the soak's main thread were other apps' threads above 31. During the loaded runs these
  included another test's AntiChat (priority 55, 100 % CPU), `swiftpm-testing-helper` (58, 100 %) and Finder (46, 100 %).

So the soak ran AntiChat's UI thread 15 priority levels below where macOS runs any GUI app's, including AntiChat's
own when a user launches it. On a busy Mac it stalled where a user's app would not.

## The method since r65

`tools/perf/soak.sh` launches the app through LaunchServices in the background, the way a user's launch is
scheduled:

```sh
open -n -g -W --env ANTICHAT_BACKGROUND=1 --env ANTICHAT_BACKGROUND_POLICY=accessory … AntiChat.app --args …
```

- `ANTICHAT_BACKGROUND_POLICY=accessory` makes `BackgroundRun` use `.accessory` instead of `.prohibited`.
  - Everything else of a background run stays: no Dock icon, concealed click-through windows (also out of window
    cycling), no activation, input in-process.
  - If the app becomes active anyway, it deactivates at once and logs it.
- `open -g` never activated the probe in any of the 15 combinations above. A shell exec of a non-`.prohibited` app
  sometimes does, which is why the soak doesn't use it.
- `soak.sh` records the app's main-thread priority (`run.json` `main_thread_priority`) and the launch mode (`launch`).
  The hang rows carry `main_pri`.
- `--launch direct` keeps the old exec launch for A/B runs.
- LaunchServices doesn't return the app's exit status. The run's `exit_code` is `open`'s. A crash still fails the
  verdict: no `result.json` and the `.ips` scan both catch it.

The other launch-time options are unchanged:
- `-ANTICHAT_DEV_CONTAINER` (a throwaway container);
- `-SoakProbe`, the fake hardware tier, real models, ScriptedVoice;
- `gpu-run.sh shared`;
- `caffeinate`.

## Results (r65, 2026-11-13)

All runs are 30-min T1 dry runs (`--minutes 30`, real models, real images) under 16 × `yes`, started together. The load
average was logged every 30 s. `gpu-run.sh shared` has two slots, so the three apps ran in staggered, overlapping
windows.

| Run | Build | Launch → main priority | App window (UTC) | Load 1-min median (range) | > 2 s | ≥ 1 s | > 250 ms | Max | Leg failures |
|---|---|---|---|---|---|---|---|---|---|
| before | instrumentation only (4a250eeaa) | direct, `.prohibited` → 31 | 03:30–04:04 | 36.6 (6.4–67.5) | 3 | 23 | 223 | 4.16 s | 2 (`model.notEnoughMemory`, project leg) |
| writer | + writer fix (da092f429) | direct, `.prohibited` → 31 | 03:51–04:25 | 44.3 (29.6–67.5) | 7 | 50 | 322 | 3.36 s | 0 |
| acc | + writer fix + this launch | LaunchServices, `.accessory` → **46** | 04:06–04:38 | 32.0 (24.4–64.2) | **0** | **0** | 21 | 0.61 s | 0 |

The fair comparison is the window both writer and acc ran in, 04:06–04:25 (load median 43.5, range 29.6–64.2). The
build and the load are the same; only the launch differs:

| Run | > 2 s | ≥ 1 s | > 250 ms | Max |
|---|---|---|---|---|
| writer (main priority 31) | 3 | 33 | 194 | 3.36 s |
| acc (main priority 46) | **0** | **0** | 14 | 0.61 s |

Every stall ≥ 1 s in the priority-31 runs was runnable-not-running: main CPU 0.02–0.63 s over 1.0–4.2 s. The acc app
never became active (no "background run became active" in its log).

Earlier sequential pairs, for the record (not side by side, so not a fair A/B):
- before 3 / 128 / 3.13 s at load median 35.9;
- writer 0 / 19 / 0.70 s at load median 27.9;
- a lone before run 0 / 33 / 1.08 s at load median 29.3.

Their spread is the load. Another agent's XCUITest AntiChat (pid 5587, priority 55, 100 % CPU) was seen at 02:10Z and was gone by 02:56Z. It was
present during those sequential runs and for at most the first 11 min of an aborted 02:45Z pair; it was gone for every
run in the table above.

The database-writer change (main-actor writes enqueued, observations off the writer, catch-up in small transactions)
is kept because a main thread must never wait for the writer. It isn't what removed these stalls: no sampled stall
was waiting on the writer.
