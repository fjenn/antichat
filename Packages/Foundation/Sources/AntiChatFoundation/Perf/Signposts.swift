// Signpost intervals (architecture.md §7.2 + the M1 additions of docs/prd/M1.md M1.T26 "Inputs"): the instruments of
// test-strategy §6 and `make perf` (tools/perf/run.py). One `OSSignposter` per category; interval names are fixed
// StaticStrings so Instruments / xctrace / XCTOSSignpostMetric can match them. M1.T26a moved this file to Perf/.
//
// Every interval that goes through `begin`/`end` (or `mark`) is also written to the in-process `PerfRecorder` when
// `ANTICHAT_PERF_LOG` is set, so `make perf` reads durations from a JSONL file without Instruments. Without the
// variable the recorder is off and the cost is one Bool check (signposts themselves are inert without collection).
//
// Who emits what (the task that owns the call site):
//   ttft, prefill, modelLoad, jobStep, routerDecision  engine/helper (M0/M1.T05)      firstPaint  renderer (M1.T09)
//   sendAck, stopToIdle                                ConversationModel (M1.T06)    paletteQuery  palette (M1.T11)
//   composerDock, sidebarUpdate                        WindowState (M1.T07)          launchToUsable  composer focus (M1.T26a)
//   titleReady                                         TitleService (M1.T19)         chatOpen  open-chat path (M1.T26b)
//   hitch (event)                                      HitchCounter (M1.T26a) while a reply streams
//   searchResults, fetchExtract, searchRank            WebSearchPipeline (M7.T03, M9.T05)  ttftSearch  ConversationModel (M7.T03)
//   quickPanelOpen                                     QuickPanelController (M8.T13)
//   imageTurn                                          TurnController (M9.T05)       imageGen  MediaJobQueue (M9.T05)
//   imageFirstVisible                                  ImageJobActivityCard (M9.T05, NFR-P2)
import Foundation
import os

public enum Signposts {
    public enum Interval: String, Sendable, CaseIterable {
        // architecture.md §7.2
        case ttft, firstPaint, prefill, modelLoad, jobStep, paletteQuery, routerDecision
        /// M1.T06: Return → user bubble + pending node + Stop committed (NFR-U2); Stop → UI idle (NFR-U6).
        case sendAck, stopToIdle
        /// M1.T26 additions: process start → composer focused (NFR-U1); first reply token → final title shown
        /// (NFR-U7); composer dock animation (AT-001, ≤ 300 ms); mutation → sidebar applied (AT-011, ≤ 100 ms);
        /// open a chat → latest screen rendered (NFR-U11).
        case launchToUsable, titleReady, composerDock, sidebarUpdate, chatOpen
        /// M1.T19: one completion pass of a turn (IS-4: ActionBar, Send, status, sidebar spinner, title together).
        case turnCompletion
        /// M2.T15 (R-206 AC5): hover hint sent → accepted by the helper's PredictiveWarmup (≤ 50 ms, AT-206 part 4).
        case warmupHint
        /// M7.T03 step 10 (R-254): web_search engines race → results; page fetch + extraction; send → first answer
        /// token of a turn that searched (AT-254, `make perf METRIC=search`).
        case searchResults, fetchExtract, ttftSearch
        /// M9.T05 (AT-254 T3 profile): chunk ranking (BM25 + embedder, reranker on T2+) and the evidence budget fit.
        case searchRank
        /// M8.T01 (R-301): the launch migration (guard → backup → migrate), category `store`; ends before the sidebar paints.
        case migration
        /// M8.T13 (NFR-U9): hotkey → quick panel shown with its field first responder (recorded with `mark`: the
        /// start is the hotkey handler's entry or the poster's clock).
        case quickPanelOpen
        /// M9.T05 (AT-236 AC3 `IMAGE_TURN_OVERHEAD`): an image turn, user send (`imageTurn.start`) → the turn's
        /// templated caption written (`imageTurn.end`), recorded with `mark` when the turn ends; and the helper's
        /// `image.loadStart` (sd-server start / reuse) → `image.final` (the job's final image), measured in the helper
        /// and marked by the app's MediaJobQueue when the job's `imageResult` arrives. Overhead = imageTurn − imageGen.
        case imageTurn, imageGen
        /// M9.T05 (NFR-P2 under A-M4-R1 / A-M4-R1b): the picture is requested (the create/edit call starts running,
        /// `ToolActivity.startedAt`) → the job card's first visible progress state is on screen (the dot matrix — or an
        /// allowed ≥ 512-px preview — with the % pill). Previews below the check's valid size are withheld, so this
        /// state is the first visible "preview" the product shows; recorded with `mark` by ImageJobActivityCard.
        case imageFirstVisible

        /// M1.T06's name for `stopToIdle` (call sites keep compiling).
        public static let stopIdle = Interval.stopToIdle
    }

    /// Point events (no duration of their own; a value travels as metadata).
    public enum Event: String, Sendable, CaseIterable {
        /// One main-thread frame > 33 ms while a reply streams (HitchCounter; NFR-U5).
        case hitch
        /// M2.T18 (NFR-M5): onboarding step-2 Continue — the clock that ends at the first token of the first chat.
        case onboardingContinue
        /// M2.T20 (NFR-M5): the first streamed token of the first chat after onboarding — the clock's end.
        case firstToken
        /// M9.T05 (NFR-B5): the helper's GPU-yield sampler changed state or held a video job paused; meta = the busiest
        /// other process and its share (the AT-NFR-B5 artefact names who kept the job paused).
        case gpuYield
    }

    public static func signposter(_ category: AppLog.Category) -> OSSignposter {
        OSSignposter(subsystem: AppLog.subsystem, category: category.rawValue)
    }

    public static let engine = signposter(.engine)
    public static let ui = signposter(.ui)
    public static let harness = signposter(.harness)

    /// Begins `interval` on `signposter`; end it with `end(_:_:on:)`.
    public static func begin(_ interval: Interval, on s: OSSignposter = engine, id: OSSignpostID? = nil) -> OSSignpostIntervalState {
        let id = id ?? s.makeSignpostID()
        let state: OSSignpostIntervalState
        switch interval {
        case .ttft: state = s.beginInterval("ttft", id: id)
        case .firstPaint: state = s.beginInterval("firstPaint", id: id)
        case .prefill: state = s.beginInterval("prefill", id: id)
        case .modelLoad: state = s.beginInterval("modelLoad", id: id)
        case .jobStep: state = s.beginInterval("jobStep", id: id)
        case .paletteQuery: state = s.beginInterval("paletteQuery", id: id)
        case .routerDecision: state = s.beginInterval("routerDecision", id: id)
        case .sendAck: state = s.beginInterval("sendAck", id: id)
        case .stopToIdle: state = s.beginInterval("stopToIdle", id: id)
        case .launchToUsable: state = s.beginInterval("launchToUsable", id: id)
        case .titleReady: state = s.beginInterval("titleReady", id: id)
        case .composerDock: state = s.beginInterval("composerDock", id: id)
        case .sidebarUpdate: state = s.beginInterval("sidebarUpdate", id: id)
        case .chatOpen: state = s.beginInterval("chatOpen", id: id)
        case .turnCompletion: state = s.beginInterval("turnCompletion", id: id)
        case .warmupHint: state = s.beginInterval("warmupHint", id: id)
        case .searchResults: state = s.beginInterval("searchResults", id: id)
        case .fetchExtract: state = s.beginInterval("fetchExtract", id: id)
        case .searchRank: state = s.beginInterval("searchRank", id: id)
        case .ttftSearch: state = s.beginInterval("ttftSearch", id: id)
        case .migration: state = s.beginInterval("migration", id: id)
        case .quickPanelOpen: state = s.beginInterval("quickPanelOpen", id: id)
        case .imageTurn: state = s.beginInterval("imageTurn", id: id)
        case .imageGen: state = s.beginInterval("imageGen", id: id)
        case .imageFirstVisible: state = s.beginInterval("imageFirstVisible", id: id)
        }
        PerfRecorder.began(interval.rawValue, state)
        return state
    }

    /// Ends `interval`. `meta` (developer values only: counts, ids, sizes, never content) goes to the perf log.
    public static func end(_ interval: Interval, _ state: OSSignpostIntervalState, on s: OSSignposter = engine,
                           meta: [String: String] = [:]) {
        switch interval {
        case .ttft: s.endInterval("ttft", state)
        case .firstPaint: s.endInterval("firstPaint", state)
        case .prefill: s.endInterval("prefill", state)
        case .modelLoad: s.endInterval("modelLoad", state)
        case .jobStep: s.endInterval("jobStep", state)
        case .paletteQuery: s.endInterval("paletteQuery", state)
        case .routerDecision: s.endInterval("routerDecision", state)
        case .sendAck: s.endInterval("sendAck", state)
        case .stopToIdle: s.endInterval("stopToIdle", state)
        case .launchToUsable: s.endInterval("launchToUsable", state)
        case .titleReady: s.endInterval("titleReady", state)
        case .composerDock: s.endInterval("composerDock", state)
        case .sidebarUpdate: s.endInterval("sidebarUpdate", state)
        case .chatOpen: s.endInterval("chatOpen", state)
        case .turnCompletion: s.endInterval("turnCompletion", state)
        case .warmupHint: s.endInterval("warmupHint", state)
        case .searchResults: s.endInterval("searchResults", state)
        case .fetchExtract: s.endInterval("fetchExtract", state)
        case .searchRank: s.endInterval("searchRank", state)
        case .ttftSearch: s.endInterval("ttftSearch", state)
        case .migration: s.endInterval("migration", state)
        case .quickPanelOpen: s.endInterval("quickPanelOpen", state)
        case .imageTurn: s.endInterval("imageTurn", state)
        case .imageGen: s.endInterval("imageGen", state)
        case .imageFirstVisible: s.endInterval("imageFirstVisible", state)
        }
        PerfRecorder.ended(interval.rawValue, state, meta: meta)
    }

    /// Records an interval whose start lies before any code of ours ran (e.g. process start → composer focus).
    /// OSSignposter cannot begin in the past, so the signpost is an event carrying the duration.
    public static func mark(_ interval: Interval, durationNs: UInt64, on s: OSSignposter = ui, meta: [String: String] = [:]) {
        let ms = Double(durationNs) / 1e6
        switch interval {
        case .launchToUsable: s.emitEvent("launchToUsable", "\(ms, privacy: .public) ms")
        case .quickPanelOpen: s.emitEvent("quickPanelOpen", "\(ms, privacy: .public) ms")
        case .imageTurn: s.emitEvent("imageTurn", "\(ms, privacy: .public) ms")
        case .imageGen: s.emitEvent("imageGen", "\(ms, privacy: .public) ms")
        case .imageFirstVisible: s.emitEvent("imageFirstVisible", "\(ms, privacy: .public) ms")
        case .paletteQuery: s.emitEvent("paletteQuery", "\(ms, privacy: .public) ms")
        default: s.emitEvent("interval", "\(interval.rawValue, privacy: .public) \(ms, privacy: .public) ms")
        }
        PerfRecorder.record(interval.rawValue, kind: .interval, durationNs: durationNs, meta: meta)
    }

    /// Emits a point event (signpost + perf log).
    public static func event(_ e: Event, on s: OSSignposter = ui, value: Double? = nil, meta: [String: String] = [:]) {
        switch e {
        case .hitch: s.emitEvent("hitch", "\(value ?? 0, privacy: .public) ms")
        case .onboardingContinue: s.emitEvent("onboardingContinue")
        case .firstToken: s.emitEvent("firstToken")
        case .gpuYield: s.emitEvent("gpuYield")
        }
        var m = meta
        if let value { m["value"] = String(value) }
        PerfRecorder.record(e.rawValue, kind: .event, durationNs: 0, meta: m)
    }

    // MARK: Launch to usable (NFR-U1)

    private static let launchMarked = OSAllocatedUnfairLock(initialState: false)

    /// M9.T05 (NFR-U1 breakdown): process start → `phase`, as a `launchPhase` record (meta `phase`) in the perf log
    /// and a signpost event. A few µs (one sysctl); call at a handful of launch milestones only.
    public static func launchPhase(_ phase: String) {
        guard let ns = ProcessClock.nanosecondsSinceProcessStart() else { return }
        ui.emitEvent("launchPhase", "\(phase, privacy: .public) \(Double(ns) / 1e6, privacy: .public) ms")
        PerfRecorder.record("launchPhase", kind: .interval, durationNs: ns, meta: ["phase": phase])
    }

    /// Call when the composer becomes first responder in a visible window. Only the first call per process counts:
    /// it records process start (kernel `p_starttime`) → now as `launchToUsable`.
    public static func markLaunchToUsable() {
        let first = launchMarked.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first, let ns = ProcessClock.nanosecondsSinceProcessStart() else { return }
        mark(.launchToUsable, durationNs: ns, on: ui)
    }
}

/// Process start time from the kernel (`sysctl kern.proc.pid`), so launch time includes dyld and static init.
public enum ProcessClock {
    public static func processStartDate(pid: pid_t = getpid()) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6)
    }

    public static func nanosecondsSinceProcessStart(now: Date = Date()) -> UInt64? {
        guard let start = processStartDate() else { return nil }
        let s = now.timeIntervalSince(start)
        return s >= 0 ? UInt64(s * 1e9) : nil
    }
}
