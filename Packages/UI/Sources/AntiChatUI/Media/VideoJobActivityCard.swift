// M5.T10 step 4 (R-040 AC1/AC2, R-043 AC1, R-290): what sits under a `create_video` tool line.
//   1. The plan card (M5.T09 VideoPlanCard) while the call waits in `VideoPlanBroker`: [Start] / the countdown hands the
//      job to the call (→ MediaJobQueue); [Cancel] / [Later] answer `.cancel` (no job is written).
//   2. Then the job: the VideoJobCard (M5.T11) — stage, real %, elapsed seconds, the animated gated preview, heat /
//      other-app pauses ([Resume]), ■ cancel. The job belongs to the helper and the app's queue, not to this view: a
//      card that comes back (navigation, a reopened window) re-attaches from the queue's snapshot.
//   3. The result: the inline player (M5.T12; poster first — written by the helper only after the gate allowed the clip —
//      then AVPlayerView, the full-window viewer and Export MP4). A withheld clip shows the blocked tile (D-006).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatPlatform
import AppKit
import SwiftUI

enum VideoJobActivity {
    /// A skipped call (a repeat, or a pack-missing call answered by the install card) never queued a job: no card
    /// (the image card had the same gap — M4.T16 Release run: "couldn't be made" + Retry beside the install card).
    static func isVideo(_ a: ToolActivity) -> Bool {
        a.kind == .tool && a.state != .skipped && VideoTurnPolicy.videoTools.contains(a.tool)
    }

    /// The card state of a call with no live job (finished before this process, or not queued).
    static func settled(_ a: ToolActivity, aspect: CGFloat) -> VideoJobCardState? {
        var s = VideoJobCardState(aspect: aspect, startedAt: a.startedAt)
        switch a.result.flatMap(VideoTurnPolicy.Outcome.parse) {
        case .done(_, let path?, _)?:
            s.progress.finished()
            s.phase = .done(resultPath: path)
        case .notShown?: s.phase = .blocked
        case .failed(let code)?: s.phase = code == "cancelled" ? .cancelled : code == "interrupted" ? .lost : .failed(code: code)
        case .notStarted?, .unavailable?, .done?, nil: return nil
        }
        return s
    }

    /// The plan's starting input on this Mac (nil until the hardware profile and catalog are known).
    @MainActor static func planInput(_ r: VideoPlanRequest) -> VideoPlanInput? {
        let m = PackManagementModel.shared
        guard let profile = m.profile, let selection = m.selection, let catalog = m.catalog else { return nil }
        return VideoPlanInput(prompt: r.prompt, intent: r.intent, sourceImageID: r.sourceImageID, isEvil: r.isEvil,
                              profile: profile, selection: selection, catalog: catalog, length: r.length, shape: r.shape,
                              sound: r.sound, history: r.history)
    }
}

struct VideoJobActivityCard: View {
    let activity: ToolActivity
    let onTryAgain: (() -> Void)?
    var messageID: String? = nil
    /// The call's plan / job key (reply id + call id; MediaCallKey).
    private var callKey: String { MediaCallKey.make(messageID: messageID, callID: activity.id) }
    @State private var plan: VideoPlanModel?
    @State private var state: VideoJobCardState?
    @State private var aspect: CGFloat = 16.0 / 9.0
    /// The queue holding the call's job (the app's, or an incognito session's own; M5.T14 review P1-1).
    @State private var queue: MediaJobQueue?

    var body: some View {
        Group {
            if let plan, plan.isVisible {
                VideoPlanCard(model: plan)
            } else if let state {
                VideoJobCard(state: state, poster: poster(state),
                             onCancel: state.job.map { job in { [queue] in Task { try? await (queue ?? MediaJobQueue.shared)?.cancel(job) } } },
                             onRetry: onTryAgain,
                             onResume: state.job.map { job in { [queue] in Task { await (queue ?? MediaJobQueue.shared)?.resume(job) } } })
            } else {
                // Before the plan exists nothing is drawn, but the view must still be there: on an empty Group the
                // `.task` below never starts, so the call waited forever for a plan card nobody built (Q-015 r2).
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .padding(.leading, Spacing.space5)
        .task(id: activity.state.rawValue) { await follow() }
    }

    private func poster(_ s: VideoJobCardState) -> String? {
        guard case .done(let path) = s.phase else { return nil }
        if case .done(_, _, let p?)? = activity.result.flatMap(VideoTurnPolicy.Outcome.parse) { return p }
        let p = VideoTurnPolicy.posterPath(forClip: path)
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Plan card while the call waits for it, then the call's job until it ends (or the settled result).
    private func follow() async {
        let broker = VideoPlanBroker.shared
        if activity.state != .running {
            state = VideoJobActivity.settled(activity, aspect: aspect) ?? state
            if state == nil || state?.isActive == false { return }
        }
        // 1. The plan card (the call publishes its request right after validation).
        for tick in 0..<600 where !Task.isCancelled && plan == nil {
            let request = await broker.request(forCall: callKey)
            // The plan needs the pack facts (profile, selection, catalog): load them if nothing has yet (a catalog that
            // arrived after launch), every 2 s while the call waits (Q-015 catch-up).
            if request != nil, VideoJobActivity.planInput(request!) == nil, tick % 20 == 0 { await PackManagementModel.shared.refresh() }
            if let r = request, let input = VideoJobActivity.planInput(r) {
                let id = callKey
                let model = VideoPlanModel(input: input,
                                           onStart: { job in Task { await broker.answer(callID: id, .start(job)) } },
                                           onCancel: { Task { await broker.answer(callID: id, .cancel) } })
                if let spec = model.plan.spec, spec.height > 0 { aspect = CGFloat(spec.width) / CGFloat(spec.height) }
                plan = model
                break
            }
            if await broker.answer(forCall: callKey) != nil || activity.state != .running { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // 2. The job (queued by the call once the card answered Start).
        var found: (queue: MediaJobQueue, job: String)?
        while !Task.isCancelled {
            found = await MediaJobQueue.job(forCall: callKey)
            if found != nil || activity.state != .running { break }
            if case .cancel? = await broker.answer(forCall: callKey) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }  // Q-015 r5: a cancelled follow's stale activity never writes (image card)
        guard let (queue, job) = found else { state = VideoJobActivity.settled(activity, aspect: aspect) ?? state; return }
        self.queue = queue
        if state == nil { state = VideoJobCardState(job: job, aspect: aspect, startedAt: activity.startedAt) }
        // The chosen clip (resolution, length, aspect) from the job's own spec.
        if let row = try? await queue.row(job), let spec = try? JSONDecoder().decode(VideoRequest.self, from: Data(row.specJSON.utf8)) {
            state?.adopt(spec)
            aspect = state?.aspect ?? aspect
            // A re-attached card keeps counting from the job's start, not from its return.
            if let started = row.startedAt { state?.startedAt = started }
        }
        let updates = await queue.subscribe()
        if let now = await queue.snapshot(job) { state?.apply(now) }
        guard state?.isActive == true else { return }
        for await u in updates where u.job == job {
            // Q-015 r5 (AT-045 AC1): the first `done` carries the helper's xfer path; the call then stores the clip
            // (artifact copy + poster) and `resultStored` publishes the stored path and deletes the xfer files. The
            // card used to stop at the first `done`, so the player and poster pointed at deleted files (error phase,
            // no poster) until the call finished. Keep following a done card until its stored path arrives.
            if case .done? = state?.phase {
                guard u.state == .done, let stored = u.resultPath else { continue }
                state?.phase = .done(resultPath: stored)
                break
            }
            state?.apply(u)
            if case .done? = state?.phase { continue }
            if state?.isActive != true { break }
        }
    }
}
