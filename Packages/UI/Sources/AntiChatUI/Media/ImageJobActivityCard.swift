// M4.T08 steps 3–5 (R-031): the ImageJobCard under a `create_image` / `edit_image` tool line. The call's job comes from
// the queue (`MediaJobQueue.job(forCall:)`); the card folds the queue's updates into its state, so switching chats and
// coming back re-attaches it to the live job (the first frame is the job's current row). A finished call whose job is
// not in this process (a relaunch) shows the stored picture from the call's result (`path`). ■ cancels the job
// (`img.cancelled` once the helper confirms); Retry re-runs the turn.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import SwiftUI

enum ImageJobActivity {
    /// A skipped call (a repeat of an earlier call, or a pack-missing call answered by the install card) never queued a
    /// job, so it gets no card: before, the Release run at T4 showed "couldn't be made" + Retry beside the install card.
    static func isImage(_ a: ToolActivity) -> Bool {
        a.kind == .tool && a.state != .skipped && ImageTurnPolicy.imageTools.contains(a.tool)
    }

    /// width / height of the picture the call asked for (aspect chip or the model's `aspect`; 1 when unknown).
    static func aspect(_ a: ToolActivity) -> CGFloat {
        if let r = a.result.flatMap(ImageTurnPolicy.Outcome.parse), case .done(_, let w?, let h?, _) = r, h > 0 {
            return CGFloat(w) / CGFloat(h)
        }
        let o = (try? JSONSerialization.jsonObject(with: Data(a.argumentsJSON.utf8))) as? [String: Any]
        return AspectChoice.all.first { $0.ratio == (o?["aspect"] as? String) }?.value ?? 1
    }

    /// width / height of the finished call's picture (nil until the call has a result with its size). M4.T16: a card
    /// that followed its live job kept the aspect it started with — 1 for an edit (edit_image names no aspect; the
    /// size comes from the source) — so a 16:9 edit result drew as a 910 × 512 card past the transcript column.
    static func resultAspect(_ a: ToolActivity) -> CGFloat? {
        guard let r = a.result.flatMap(ImageTurnPolicy.Outcome.parse), case .done(_, let w?, let h?, _) = r, w > 0, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    /// The card state as drawn: the result's aspect once known.
    static func shown(_ s: ImageJobCardState, _ a: ToolActivity) -> ImageJobCardState {
        var s = s
        if let r = resultAspect(a) { s.aspect = r }
        return s
    }

    /// The chat's stored copy of a finished call's picture (the artifact with the AI mark; nil until the call ends).
    static func storedPath(_ a: ToolActivity) -> String? {
        guard case .done(_, _, _, let path?)? = a.result.flatMap(ImageTurnPolicy.Outcome.parse) else { return nil }
        return path
    }

    /// The chat's artifact id of a finished call's picture (the viewer's version rail).
    static func artifactID(_ a: ToolActivity) -> String? {
        guard case .done(let id, _, _, _)? = a.result.flatMap(ImageTurnPolicy.Outcome.parse) else { return nil }
        return id
    }

    /// The card state of a call with no live job (finished before this process, or not queued).
    static func settled(_ a: ToolActivity) -> ImageJobCardState? {
        var s = ImageJobCardState(aspect: aspect(a), startedAt: a.startedAt)
        switch a.result.flatMap(ImageTurnPolicy.Outcome.parse) {
        case .done(_, _, _, let path?)?:
            s.progress.finished()
            s.phase = .done(resultPath: path)
        case .notShown?: s.phase = .blocked
        case .failed(let code)?: s.phase = code == "cancelled" ? .cancelled : code == "interrupted" ? .lost : .failed(code: code)
        case .safetyMissing(let n)?: s.phase = .safetyMissing(sizeBytes: n)
        // M4.T16: the call ended without a job (the photo models of this Mac could not be resolved): an error card
        // with Retry, never a "Creating image 0 %" placeholder that counts up forever.
        case .unavailable?: s.phase = .failed(code: "unavailable")
        case .done?, nil:
            if a.state == .running { return s }
            if a.state == .failed { s.phase = .failed(code: "failed"); return s }
            return nil
        }
        return s
    }
}

struct ImageJobActivityCard: View {
    let activity: ToolActivity
    let onTryAgain: (() -> Void)?
    var messageID: String? = nil
    /// The call's job key (reply id + call id; MediaCallKey).
    private var callKey: String { MediaCallKey.make(messageID: messageID, callID: activity.id) }
    @State private var state: ImageJobCardState?
    @Environment(\.openImageViewer) private var openViewer

    /// M4.T13: Edit on a stored picture opens the viewer with Describe the change focused.
    private var onEdit: ((String) -> Void)? {
        guard let openViewer, let artifact = ImageJobActivity.artifactID(activity) else { return nil }
        return { path in
            openViewer(ImageViewerTarget(paths: [path], selected: 0, artifactID: artifact, current: path, focusDescribe: true))
        }
    }
    /// The queue holding the call's job (the app's, or an incognito session's own; M5.T14 review P1-1).
    @State private var queue: MediaJobQueue?
    @State private var firstVisibleMarked = false

    /// M9.T05 (NFR-P2 under A-M4-R1b): the picture was requested (this call started running) → its first visible
    /// progress state is on screen. Once per card, and only for a live call (a card re-shown later is not a request).
    private func markFirstVisible() {
        guard !firstVisibleMarked, activity.state == .running else { return }
        firstVisibleMarked = true
        let s = max(0, Date().timeIntervalSince(activity.startedAt))
        Signposts.mark(.imageFirstVisible, durationNs: UInt64(s * 1e9), on: Signposts.ui,
                       meta: ["tool": activity.tool, "preview": state?.previewPath == nil ? "0" : "1"])
    }
    @Environment(\.animateImage) private var animateImage

    var body: some View {
        // Never an empty view: SwiftUI does not start `.task` on empty content, so with `state` still nil the card
        // never attached to its job and never appeared (M4.T16: the scripted journey's done card was missing).
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            if let state = state.map({ ImageJobActivity.shown($0, activity) }) {
                ImageJobCard(state: state, promptUsed: ImageTools.promptUsed(argumentsJSON: activity.argumentsJSON),
                             savePath: ImageJobActivity.storedPath(activity), artifactID: ImageJobActivity.artifactID(activity),
                             onEdit: onEdit,
                             onCancel: state.job.map { job in { [queue] in Task { try? await (queue ?? MediaJobQueue.shared)?.cancel(job) } } },
                             onRetry: onTryAgain, onAnimate: animateAction,
                             onRestart: state.phase == .lost && (state.job != nil || messageID != nil) ? { restart(lostJob: state.job) } : nil,
                             onProgressShown: markFirstVisible)
                    .padding(.leading, Spacing.space5)
            }
        }
        .task(id: activity.state.rawValue) { await follow() }
    }

    /// R-291 AC2 [Restart]: the interrupted job (this process's, or the reply's lost row after a relaunch) runs again;
    /// the card follows the new job and ends on the call's new outcome (stored with the reply by ImageTools).
    private func restart(lostJob: String?) {
        let activity = activity, messageID = messageID, key = callKey
        Task { @MainActor in
            var target: (queue: MediaJobQueue, job: String)?
            if let lostJob, let q = queue ?? MediaJobQueue.shared { target = (q, lostJob) }
            if target == nil, let messageID { target = await MediaJobQueue.lostJob(messageID: messageID) }
            guard let (q, job) = target else { return }
            queue = q
            state = ImageJobCardState(aspect: ImageJobActivity.aspect(activity), startedAt: Date())
            let updates = await q.subscribe()
            let run = Task { await ImageTools.restartInterrupted(job: job, queue: q, activity: activity, messageID: messageID, callKey: key) }
            // Follow the new job's progress (it is mapped to this card's key as soon as it is queued).
            var newJob: String?
            for _ in 0..<50 where newJob == nil {
                if let j = await q.job(forCall: key), j != job { newJob = j } else { try? await Task.sleep(for: .milliseconds(20)) }
            }
            if let newJob {
                if let now = await q.snapshot(newJob) { state?.apply(now) }
                for await u in updates where u.job == newJob {
                    state?.apply(u)
                    if state?.isActive != true { break }
                }
            }
            var done = activity
            done.result = await run.value.resultJSON
            done.state = .done
            state = ImageJobActivity.settled(done) ?? state
        }
    }

    /// M5.T10: Animate the finished picture (its artifact id from the call's result).
    private var animateAction: (() -> Void)? {
        guard let animateImage, let r = activity.result.flatMap(ImageTurnPolicy.Outcome.parse),
              case .done(let id, _, _, _) = r, !id.isEmpty else { return nil }
        return { animateImage(id) }
    }

    /// How long a running call may go without a queued job before the card shows the error.
    static let attachTimeout = Duration.seconds(60)

    /// A card left without a job and without a settled result: never an active placeholder.
    static func unattached(_ s: ImageJobCardState?) -> ImageJobCardState? {
        guard var s, s.isActive else { return s }
        s.phase = .failed(code: MediaJobQueue.notStartedCode)
        return s
    }

    /// Attaches to the call's job and follows it until it ends (or shows the settled result).
    private func follow() async {
        // A finished call whose detectors were missing shows the repair card with the real size (the queue's row has none).
        if let s = ImageJobActivity.settled(activity), case .safetyMissing = s.phase { state = s; return }
        if state == nil { state = ImageJobActivity.settled(activity) ?? ImageJobCardState(aspect: ImageJobActivity.aspect(activity), startedAt: activity.startedAt) }
        guard !MediaJobQueue.all.isEmpty else {
            if activity.state != .running { state = ImageJobActivity.settled(activity) }
            return
        }
        var found: (queue: MediaJobQueue, job: String)?
        let attachBy = ContinuousClock.now + Self.attachTimeout
        while !Task.isCancelled {  // the call queues its job right after validation
            found = await MediaJobQueue.job(forCall: callKey)
            if found != nil || activity.state != .running { break }
            // Q-015 r5 (R-285 AC6): a call that ended without a job (missing detectors) settles from its recorded
            // result; the row may not hand this card the finished activity (it stayed "Creating image 0 %").
            // R-291 AC2: after a quit or crash this process never queued the call's job; its row (reconciled `lost`
            // at launch) is found by the reply id, and the card offers Restart.
            if let messageID, let lost = await MediaJobQueue.lostJob(messageID: messageID) {
                queue = lost.queue
                state?.job = lost.job
                state?.phase = .lost
                return
            }
            if let r = MediaJobQueue.joblessResult(forCall: callKey) {
                var done = activity
                done.result = r
                state = ImageJobActivity.settled(done) ?? state
                return
            }
            // M4.T16: a running call that queued no job within the bound shows the error (Retry); it keeps looking,
            // so a job queued later still attaches.
            if ContinuousClock.now > attachBy, state?.isActive == true { state?.phase = .failed(code: MediaJobQueue.notStartedCode) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // Q-015 r5: a follow cancelled by the call's state change (`.task(id:)`) must not write: its `activity` is the
        // stale running one, and its placeholder overwrote the newer follow's settled card (the safety-missing repair
        // card went back to "Creating image 0 %").
        guard !Task.isCancelled else { return }
        guard let (queue, job) = found else { state = ImageJobActivity.settled(activity) ?? Self.unattached(state); return }
        self.queue = queue
        let updates = await queue.subscribe()
        if let now = await queue.snapshot(job) { state?.apply(now) }
        guard state?.isActive == true else { return }
        for await u in updates where u.job == job {
            state?.apply(u)
            if state?.isActive != true { break }
        }
    }
}
