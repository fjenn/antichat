// Renderer instrumentation (M1.T09; AT-008 leg 4, NFR-U5). DEBUG builds only do anything here.
// - `RendererCPUThrottle`: `-RendererCPUScale s` (M1.md convention 5, S1 stand-in, `[ASSUMPTION]`): after each
//   main run-loop pass while a reply streams, the main thread busy-waits (1/s − 1) × that pass's duration, so all
//   main-thread work (SwiftUI updates, layout, the renderer's applies) takes 1/s as long, as on a slower CPU.
//   It also counts main-thread passes > 33 ms (the hitch counter of the pass condition) while streaming.
// - `MarkdownProbe`: in-process counters the RendererProbe (App, `-RendererProbe <dir>`) reads: reveal applies,
//   parse-result commits, fade activity.
import AntiChatFoundation
import CoreFoundation
import Foundation
import QuartzCore

@MainActor
public final class RendererCPUThrottle {
    public static let shared = RendererCPUThrottle()

    public private(set) var scale: Double?
    /// Main-thread passes while a reply streamed, and how many exceeded 33 ms (the hitch counter).
    public private(set) var passes = 0
    public private(set) var hitches = 0
    public private(set) var longestPassMs: Double = 0
    /// Passes over 100 ms (end time CACurrentMediaTime, scaled ms), so a probe can place them in the reply's timeline
    /// (fix/u5-renderer-2: the long-chat run had one 1.1 s pass at scale 1).
    public private(set) var longPasses: [(end: Double, ms: Double)] = []
    /// Every pass over 33 ms (the hitches), end time CACurrentMediaTime and scaled ms (fix/u5-renderer-4: when they
    /// happen in the reveal).
    public private(set) var hitchPasses: [(end: Double, ms: Double)] = []
    private var observer: CFRunLoopObserver?
    private var passStart: Double = 0
    private var lastActive: Double = -1

    private init() {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        scale = LaunchOptions.current.rendererCPUScale.flatMap { $0 > 0 && $0 < 1 ? $0 : nil }
        #endif
    }

    /// A reveal applied: count the next passes as "streaming" for 0.5 s.
    func noteActive() {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        lastActive = CACurrentMediaTime()
        install()
        #endif
    }

    public func reset() {
        passes = 0
        hitches = 0
        longestPassMs = 0
        longPasses = []
        hitchPasses = []
    }

    private func install() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { _, activity in
            MainActor.assumeIsolated { RendererCPUThrottle.shared.handle(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }

    private func handle(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            passStart = now
            return
        }
        guard passStart > 0, now - lastActive < 0.5 else { return }
        var elapsed = now - passStart
        if let s = scale {
            let extra = min(0.25, elapsed * (1 / s - 1))
            let until = now + extra
            while CACurrentMediaTime() < until {}  // busy time on the main thread (S1 stand-in)
            elapsed += extra
        }
        passes += 1
        let ms = elapsed * 1000
        longestPassMs = max(longestPassMs, ms)
        if ms > 100, longPasses.count < 200 { longPasses.append((passStart + elapsed, ms)) }
        if ms > 33 {
            hitches += 1
            if hitchPasses.count < 5000 { hitchPasses.append((passStart + elapsed, ms)) }
        }
        passStart = 0
    }
}

/// In-process renderer counters for the AT-008 probe. `current` is nil unless a probe installed one.
@MainActor
public final class MarkdownProbe {
    public static var current: MarkdownProbe?

    public struct Sample: Sendable {
        public var time: Double; public var words: Int
        /// Revealed UTF-8 bytes and blocks after this apply (where in the reply it happened).
        public var bytes = 0, blocks = 0
    }
    public private(set) var applies: [Sample] = []
    public private(set) var commits: [Double] = []
    /// Display frames in which reply text was drawn mid-fade (a fading draw of a Text longer than
    /// `FadeLedger.bodyChars`, since the previous display frame).
    public private(set) var fadeFrames = 0
    /// The same for any Text, the code / table header labels included (the old counter's view).
    public private(set) var anyFadeFrames = 0
    /// Word-fade renderer draws summed over the attached replies (all / mid-fade / reply text / reply text mid-fade).
    /// `bodyDraws` 0 while text streams = the renderer is not drawing the reply text at all.
    public private(set) var fadeDraws = (draws: 0, fading: 0, body: 0, bodyFading: 0)
    private var binders: [ObjectIdentifier: () -> FadeLedger.Counters] = [:]
    private var sampled = FadeLedger.Counters()

    public init() {}

    func attach(_ binder: StreamingMarkdownBinder) {
        binder.onApply = { [weak self, weak binder] t, w in
            self?.applies.append(Sample(time: t, words: w, bytes: binder?.appliedBytes ?? 0, blocks: binder?.blocks.count ?? 0))
        }
        binders[ObjectIdentifier(binder)] = { [weak binder] in binder?.ledger.probeCounters ?? FadeLedger.Counters() }
    }

    func noteCommit() { commits.append(CACurrentMediaTime()) }

    /// Samples the fade state (call once per display frame from the probe): did a fading draw happen since the
    /// previous frame?
    public func sampleFade() {
        var sum = FadeLedger.Counters()
        for c in binders.values.map({ $0() }) {
            sum.draws += c.draws
            sum.fadingDraws += c.fadingDraws
            sum.bodyDraws += c.bodyDraws
            sum.bodyFadingDraws += c.bodyFadingDraws
        }
        if sum.bodyFadingDraws > sampled.bodyFadingDraws { fadeFrames += 1 }
        if sum.fadingDraws > sampled.fadingDraws { anyFadeFrames += 1 }
        sampled = sum
        fadeDraws = (sum.draws, sum.fadingDraws, sum.bodyDraws, sum.bodyFadingDraws)
    }

    public func reset() {
        applies = []
        commits = []
        fadeFrames = 0
        anyFadeFrames = 0
    }
}
