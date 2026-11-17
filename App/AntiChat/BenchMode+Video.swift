// M0.T07 bench command (S-10): `AntiChat -Bench video …`, through the real XPC path into the helper's
// EngineRuntime (ModelScheduler job) → MediaJobRunner → VideoEngine (M5.T03: the runtime server; every preview and the
// final frames go through the gate; M5.T06: only an allowed clip is written, as an MP4 by MP4Encoder after `checkVideo`).
// Safety floor (M0.md M0.T07, D-006): clips and previews are files only, never shown in any UI; prompts are
// fixed benign scenes (landscapes, objects); raw rows carry hashes.
//   video --mode t2v --res 480p|720p --frames 73 --runs 3 --tier-cap T3-48 --runtime DIR --out-dir DIR
//         [--events FILE] [--cancel-at-step K]          NFR-VID1 (request → MP4), VID2 (request → first preview)
//         [--model vid-5b|vid-ltx] [--width W --height H] [--no-audio]   (fix/t05-video, AT-290: an unknown --res or
//         --model fails; vid-ltx = LTX-2.3 with sound from the dev cache's vid-ltx + vid-ltx-te)
//   Rows: `low_tier` (the app's tier rule for the cap), `model_key` / `model_kind` (requested), `meta_width` ×
//   `meta_height` (actual, from the runtime), `h_child_*` (the runtime's stage clock, `videoRuntimeMetrics`).
//   video --mode i2v --init-image PATH --res 480p --frames 73 --steps 20 --runs 1 --out-dir DIR [--events FILE]
//   video --installed <Models dir> --runtime DIR [--evil] [--runs N] --out-dir DIR [--events FILE]
//         (fix/t4-video) the app's own resolution instead of the dev cache: this Mac's live hardware profile → the
//         bundled signed catalog's selection → the plan card's default text-to-video job (VideoPlan, tier presets) →
//         InstalledVideoModels.request over `<Models dir>/installs` (catalog install views, e.g. `antichat-cli models
//         install|import`). Fails when the app would show the job as unavailable.
// Developer-only: compiled in DEBUG and perf-harness builds, never in a release (tools/ci/dev-modes-guard.py).
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatHarness
import AntiChatPlatform
import AntiChatUI
import Darwin
import Foundation

extension BenchMode {
    /// Benign scenes only (landscapes, objects); seed per prompt.
    static let videoPrompts: [(String, Int64)] = [
        ("A calm mountain lake at sunrise, mist drifting over the water, pine trees on the shore", 1),
        ("A red vintage bicycle leaning against an old stone wall, autumn leaves on the cobblestones", 2),
        ("Ocean waves rolling onto a sandy beach under a clear blue sky, slow camera pan", 3),
    ]
    static let videoI2VPrompt = "Gentle ripples on a calm lake, clouds drifting slowly across the sky, soft light"

    struct VideoRun {
        var progress: [VideoProgress] = []
        var firstStep: Double?
        var firstPreview: Double?
        var final: Double?
        var result: VideoResult?
        var notes: [SchedulerNote] = []
        var error: String?
        var childPID: Int32 = 0
        var cancelSentAt: Double?
        /// The runner's terminal job event (M5.T06+: an allowed clip ends `jobResult`, written after the gate).
        var jobEnd: MediaJobEvent?
        var denoiseDone: Double?
        var framesReady: Double?
        /// fix/t05-video-t4 (VID2): previews the gate allowed and the runner announced (`jobProgress` with a preview
        /// file, the event the app's card shows), and the step of the first one.
        var previewsShown = 0
        var firstPreviewStep: Int?
    }

    /// fix/t05-video (F7_VIDEO): the tier rule the app would send (AppBootstrap `lowTier: tier <= .T2`). A tier cap
    /// names its tier (`T2-24` → T2, `T3-48` → T3); `none` and `--installed` use this Mac's live profile, as the app does.
    /// Before this the bench always ran lowTier (the SetPolicy default): a T3/T4 job never preloaded the detectors and
    /// never streamed its final check, so F7_VIDEO measured the T0–T2 path under a T3/T4 label.
    static func videoLowTier(_ a: Args, cap: String) -> Bool {
        if a.opts["installed"] == nil, cap != "none", let t = HardwareTier(rawValue: String(cap.prefix(2))) { return t <= .T2 }
        let facts = HardwareProbe.liveFacts(includeDisk: false)
        return TierClassifier.classify(facts: facts).tier <= .T2
    }

    static func video(_ a: Args, client: EngineClient, ack: HelloAck, raw: RawWriter, base: [String: Any]) async throws {
        let mode = VideoRequest.Mode(rawValue: a.opts["mode"] ?? "t2v") ?? .t2v
        let pids = PIDSet()
        let events = RawWriter(a.opts["events"])
        let runs = a.int("runs", mode == .t2v ? 3 : 1)
        for i in 0..<runs {
            var req = try a.opts["installed"] != nil ? installedVideoRequest(a, i: i) : videoRequest(a, mode: mode, i: i)
            // M9.T05 (F7_VIDEO): the dev-models path checks its clips too (the detectors `-Bench image` uses), so the
            // gate's time is part of every bench job; without detectors the helper fails closed (D-006).
            if req.safety == nil { req.safety = benchSafety }
            // fix/t05-video-t4 (VID2): a preview folder, as the app's queue gives every job (MediaJobQueue's xfer dir):
            // without one an allowed preview is announced without a file and the row could not see it. Benign scenes;
            // files only, never shown (safety floor above); the folder is removed after the run.
            if req.previewDir == nil { req.previewDir = (req.scratchDir as NSString).appendingPathComponent("previews") }
            let s = sampler(ack, pids)
            let r = await runVideo(client, req, cancelAtStep: a.opts["cancel-at-step"].flatMap(Int.init), pids: pids, events: events, run: i)
            let peak = s.stop()
            raw.write(videoRow(base, a, req, run: i, r, peak: peak))
            if let dir = req.previewDir { try? FileManager.default.removeItem(atPath: dir) }
            say(String(format: "video %@ %d: final %.1fs first step %.1fs first preview %.1fs steps %d previews %d peak %.2f GB %@",
                        mode.rawValue, i, r.final ?? -1, r.firstStep ?? -1, r.firstPreview ?? -1,
                        r.progress.filter { $0.stage == "step" || ($0.stage == "denoise" && $0.step >= 1) }.count, r.previewsShown + r.progress.filter { $0.previewPath != nil }.count,
                        Double(peak) / 1e9, r.error ?? r.result?.status ?? r.jobEnd.map { "\($0)" } ?? ""))
        }
    }

    /// `--installed`: the request the app builds for the plan card's default text-to-video job on this Mac.
    static func installedVideoRequest(_ a: Args, i: Int) throws -> VideoRequest {
        func fail(_ m: String) -> NSError { NSError(domain: "bench", code: 2, userInfo: [NSLocalizedDescriptionKey: m]) }
        guard let models = a.opts["installed"], let runtime = a.opts["runtime"] else { throw fail("--installed and --runtime required") }
        guard let baseline = CatalogStore.bundledBaseline() else { throw fail("no bundled catalog") }
        let catalog = try ModelCatalog.decode(baseline.data)
        let facts = HardwareProbe.liveFacts(includeDisk: false)
        let profile = HardwareProfile(facts: facts, classification: TierClassifier.classify(facts: facts))
        let evil = a.opts["evil"] != nil
        let selection = ModelSelector(catalog: catalog).select(profile: profile, modes: [.normal, .evil])
        let (prompt, seed) = videoPrompts[i % videoPrompts.count]
        let input = VideoPlanInput(prompt: prompt, intent: .createVideoChip, isEvil: evil, profile: profile, selection: selection,
                                   catalog: catalog)
        guard let job = VideoPlan.make(input).job else { throw fail("no plan job for \(profile.tierKey)/\(profile.speedClass.rawValue)") }
        guard var req = InstalledVideoModels.request(job, sourceImagePath: nil, seed: seed, isEvil: evil, catalog: catalog,
                                                     installs: URL(fileURLWithPath: models).appendingPathComponent("installs"),
                                                     runtime: URL(fileURLWithPath: runtime), budget: UInt64(max(0, profile.B) * 1e9))
        else { throw fail("unavailable: \(job.spec.model) is not fully installed under \(models)") }
        // The app's queue: the detectors from the same install views (MediaJobQueue → InstalledPhotoModels.safetyManifest).
        req.safety = InstalledPhotoModels.safety(selection: selection, catalog: catalog,
                                                 installs: URL(fileURLWithPath: models).appendingPathComponent("installs"), requireSlot: false)
        let tag = "t2v-\(profile.tierKey)-\(job.spec.model)-\(job.spec.width)x\(job.spec.height)-\(job.spec.frames)f\(evil ? "-evil" : "")-\(String(format: "%02d", i))"
        let outDir = a.opts["out-dir"] ?? "build/at/T4-video/out"
        req.outputPath = (URL(fileURLWithPath: outDir).appendingPathComponent("\(tag).mp4").path as NSString).standardizingPath
        req.scratchDir = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-video/\(tag)").path
        say("video --installed: \(profile.tierKey)/\(profile.speedClass.rawValue) model \(job.spec.model) \(job.spec.width)x\(job.spec.height) \(job.spec.frames) f, \(job.spec.steps) steps, taehv \(req.taehv)")
        return req
    }

    /// fix/t05-video (AT-290): the clip size of a dev-models request. `--width W --height H` (both) win; else `--res`,
    /// which must be one this bench knows — an unknown value (e.g. `ltx`) used to fall back to 832×480 silently.
    static func videoSize(_ a: Args) throws -> (Int, Int) {
        func fail(_ m: String) -> NSError { NSError(domain: "bench", code: 64, userInfo: [NSLocalizedDescriptionKey: m]) }
        if a.opts["width"] != nil || a.opts["height"] != nil {
            guard let w = a.opts["width"].flatMap(Int.init), let h = a.opts["height"].flatMap(Int.init), w > 0, h > 0 else {
                throw fail("--width and --height go together (positive integers)")
            }
            return (w, h)
        }
        switch a.opts["res"] ?? "480p" {
        case "480p": return (832, 480)
        case "720p": return (1280, 704)
        case let r: throw fail("unknown --res \(r); one of 480p, 720p (or --width W --height H)")
        }
    }

    static func videoRequest(_ a: Args, mode: VideoRequest.Mode, i: Int) throws -> VideoRequest {
        let d = DevModels.modelsDir
        let (w, h) = try videoSize(a)
        let frames = a.int("frames", 73)
        let outDir = a.opts["out-dir"] ?? "build/at/AT-M0-07/out"
        let model = a.opts["model"] ?? (mode == .t2v ? "vid-5b" : "vid-i2v")
        let tag = "\(mode.rawValue)-\(model)-\(w)x\(h)-\(frames)f-\(String(format: "%02d", i))"
        let out = (URL(fileURLWithPath: outDir).appendingPathComponent("\(tag).mp4").path as NSString).standardizingPath
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("antichat-video/\(tag)").path
        let budget = UInt64((DevModels.tierB[a.opts["tier-cap"] ?? "none"] ?? 0) * 1e9)
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        switch mode {
        case .t2v:
            let (p, seed) = videoPrompts[i % videoPrompts.count]
            guard let runtime = a.opts["runtime"] else { throw NSError(domain: "bench", code: 2, userInfo: [NSLocalizedDescriptionKey: "--runtime DIR required"]) }
            switch model {
            case "vid-5b":
                // 11.1 GiB measured TE peak at 480p (S-10) + 10%; 720p denoise peak is lower than the TE stage.
                return VideoRequest(mode: .t2v, prompt: p, width: w, height: h, frames: frames, seed: seed, runtimeDir: runtime,
                                    modelDir: d.appendingPathComponent("vid-5b").path,
                                    taehv: d.appendingPathComponent("vid-taehv/taew2_2.safetensors").path,
                                    outputPath: out, scratchDir: scratch, footprintBytes: UInt64(13e9), memoryLimitBytes: budget)
            case "vid-ltx":
                // fix/t05-video (AT-290 t2v-ltx-512p-short): LTX-2.3 with sound, as InstalledVideoModels builds it
                // (model dir + Gemma text encoder dir `vid-ltx-te` + `audio`; no TAEHV). 24.9 GiB measured decode peak
                // (AT-292) + 10 %.
                var r = VideoRequest(mode: .t2v, prompt: p, width: w, height: h, frames: frames, seed: seed, runtimeDir: runtime,
                                     modelDir: DevModels.view("vid-ltx").path, taehv: "", outputPath: out, scratchDir: scratch,
                                     footprintBytes: UInt64(29.4e9), memoryLimitBytes: budget)
                r.modelKind = "ltx"
                r.gemmaDir = DevModels.view("vid-ltx-te").path
                r.audio = a.opts["no-audio"] == nil
                return r
            default:
                throw NSError(domain: "bench", code: 64, userInfo: [NSLocalizedDescriptionKey: "unknown t2v --model \(model); one of vid-5b, vid-ltx"])
            }
        case .i2v:
            guard model == "vid-i2v" else {
                throw NSError(domain: "bench", code: 64, userInfo: [NSLocalizedDescriptionKey: "unknown i2v --model \(model); vid-i2v only"])
            }
            return VideoRequest(mode: .i2v, prompt: videoI2VPrompt, width: w, height: h, frames: frames, seed: Int64(i + 1),
                                taehv: a.opts["full-vae"] != nil ? "" : d.appendingPathComponent("vid-taehv/taew2_2.safetensors").path,
                                sdCLI: a.opts["sd-cli"] ?? helpers.appendingPathComponent("sd-cli").path,
                                diffusionModel: d.appendingPathComponent("vid-i2v/Wan2.2-TI2V-5B-Q8_0.gguf").path,
                                vae: d.appendingPathComponent("vid-i2v/VAE/Wan2.2_VAE.safetensors").path,
                                t5xxl: d.appendingPathComponent("vid-te/umt5-xxl-encoder-Q8_0.gguf").path,
                                initImage: a.opts["init-image"], steps: a.int("steps", 20), cfgScale: 6, flowShift: 3,
                                outputPath: out, scratchDir: scratch, footprintBytes: UInt64(16e9), memoryLimitBytes: budget)
        }
    }

    static func runVideo(_ client: EngineClient, _ req: VideoRequest, cancelAtStep: Int?, pids: PIDSet, events: RawWriter, run: Int) async -> VideoRun {
        var r = VideoRun()
        let sent = ContinuousClock.now
        var cancelled = false
        for await batch in client.video(req) {
            for e in batch.items {
                let t = secs(batch.receivedAt - sent)
                switch e {
                case .media(.videoProgress(let p)):
                    r.progress.append(p)
                    if p.childPID > 0 { r.childPID = p.childPID; pids.insert(p.childPID) }
                    if p.stage == "step" || (p.stage == "denoise" && p.step >= 1), r.firstStep == nil { r.firstStep = t }
                    if p.stage == "denoise", p.step == p.totalSteps, p.totalSteps > 0 { r.denoiseDone = t }
                    if p.stage == "frames" { r.framesReady = t }
                    if p.previewPath != nil, r.firstPreview == nil { r.firstPreview = t }
                    events.write(["run": run, "mode": req.mode.rawValue, "t_app": t, "t_helper": p.t, "stage": p.stage, "step": p.step,
                                  "total": p.totalSteps, "preview": p.previewPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? NSNull(),
                                  "preview_bytes": p.previewBytes, "preview_sha256": p.previewSHA256, "child_pid": p.childPID])
                    if let c = cancelAtStep, p.stage == "step", p.step >= c, !cancelled {
                        cancelled = true
                        r.cancelSentAt = t
                        client.cancel(req.requestID)
                    }
                case .media(.job(.jobProgress(_, let step, let total, let path?))):
                    // fix/t05-video-t4 (VID2): the path the app's card takes (MediaJobQueue.progressed → VideoJobStatus):
                    // a preview that passed the gate and was written. `.videoProgress` never carries one.
                    r.previewsShown += 1
                    if r.firstPreview == nil { r.firstPreview = t; r.firstPreviewStep = step }
                    events.write(["run": run, "mode": req.mode.rawValue, "t_app": t, "stage": "preview", "step": step, "total": total,
                                  "preview": URL(fileURLWithPath: path).lastPathComponent,
                                  "preview_bytes": (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1])
                case .media(.scheduler(let n)): r.notes.append(n)
                case .media(.job(let j)) where j.isTerminal:
                    r.jobEnd = j
                    if r.final == nil { r.final = t }
                case .media(.videoResult(let res)):
                    r.final = t
                    r.result = res
                case .engine(.error(let err)): r.error = err.description
                default: break
                }
            }
        }
        return r
    }

    /// The runtime's stage metrics of one completed job (`videoRuntimeMetrics` note), parsed; empty when absent.
    static func videoChildMetrics(_ notes: [SchedulerNote]) -> [String: Double] {
        guard let n = notes.last(where: { $0.action == "videoRuntimeMetrics" }) else { return [:] }
        return n.detail.compactMapValues(Double.init)
    }

    static func videoRow(_ base: [String: Any], _ a: Args, _ req: VideoRequest, run i: Int, _ r: VideoRun, peak: UInt64) -> [String: Any] {
        var o = base
        o["run"] = i
        o["mode"] = req.mode.rawValue
        // --installed jobs take their size from the VideoPlan (T4 default 1280×704), not from --res: label by the request.
        o["res"] = a.opts["installed"] != nil ? "\(min(req.width, req.height))p" : (a.opts["res"] ?? "480p")
        o["load_avg"] = ProcessInfo.processInfo.loadAverage1m
        o["width"] = req.width
        o["model_dir"] = req.modelDir
        // fix/t05-video (AT-290): what the job was asked to run, for the driver's requested-vs-actual check (the actual
        // size is `meta_width` × `meta_height`, from the runtime's `frames_ready`, written with the MP4).
        o["model_key"] = req.mode == .i2v ? URL(fileURLWithPath: req.diffusionModel).deletingLastPathComponent().lastPathComponent
                                          : URL(fileURLWithPath: req.modelDir).lastPathComponent
        o["model_kind"] = req.modelKind ?? "wan22"
        o["taehv"] = req.taehv
        o["installed"] = a.opts["installed"] != nil
        o["steps"] = req.steps
        o["height"] = req.height
        o["frames"] = req.frames
        o["seed"] = req.seed
        o["final_s"] = r.final ?? -1
        o["first_step_s"] = r.firstStep ?? -1
        o["first_preview_s"] = r.firstPreview ?? -1
        o["step_events"] = r.progress.filter { $0.stage == "step" }.count
        // fix/t05-video-t4 (VID2): previews shown = gate-allowed previews announced to the app (`jobProgress` with a file).
        o["preview_events"] = r.previewsShown + r.progress.filter { $0.previewPath != nil }.count
        o["first_preview_step"] = r.firstPreviewStep ?? -1
        o["stages"] = r.progress.filter { $0.stage != "step" }.map(\.stage).joined(separator: ",")
        o["peak_footprint_bytes"] = peak
        o["child_pid"] = r.childPID
        o["cancel_sent_s"] = r.cancelSentAt ?? -1
        o["child_alive_after"] = r.childPID > 0 && kill(r.childPID, 0) == 0
        if let res = r.result {
            o["status"] = res.status
            o["sha256"] = res.sha256
            o["mp4_bytes"] = res.bytes
            o["out_width"] = res.width
            o["out_height"] = res.height
            o["out_frames"] = res.frames
            o["path"] = res.path
            for (k, v) in res.metrics { o["h_\(k)"] = v }
        }
        o["notes"] = r.notes.map { n in
            (["action": n.action, "model": n.model, "seconds": n.seconds] as [String: Any]).merging(n.detail.mapValues { $0 as Any }) { $1 }
        }
        // fix/t05-video (AT-290 a): the runtime's stage clock (VideoEngine `videoRuntimeMetrics` note, its `end` event's
        // metrics) as `h_child_<key>`, the columns the M0 rows carried and tools/perf/video-speed.py splits by.
        for (k, v) in videoChildMetrics(r.notes) { o["h_child_\(k)"] = v }
        o["denoise_done_s"] = r.denoiseDone ?? -1
        o["frames_ready_s"] = r.framesReady ?? -1
        switch r.jobEnd {
        case .jobResult(_, let path, let meta)?:
            o["status"] = "completed"
            o["path"] = path
            o["mp4_bytes"] = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1
            for (k, v) in meta { o["meta_\(k)"] = v }
        case .jobBlocked?: o["status"] = "blocked"
        case .safetyMissing?: o["status"] = "safetyMissing"
        case .jobCancelled?: o["status"] = "cancelled"
        case .jobFailed(_, let code)?: o["status"] = "failed"; o["error"] = code
        default: break
        }
        if let e = r.error { o["error"] = e }
        return o
    }
}
#endif
