// fix/selection-hang guard (no XCUITest): a transcript that is only *waiting* — a pending reply's pulsing dot, a
// picture job's dot-matrix placeholder — next to selectable text must cost the main thread ~nothing. XCUITest round 4
// hung ("main thread busy 30 s", 39 MB → 1.3 GB): every display frame of a SwiftUI `repeatForever` /
// `TimelineView(.animation)` ran a window-wide transaction that re-placed the LazyVStack and re-updated each
// selectable Text's SelectionOverlay. The always-on animations are Core Animation layer animations now.
// Each case hosts the views in a (concealed) window for `seconds` and measures the main thread's CPU time, the hosting
// view's layout passes and the footprint. Before the fix (same harness, a concealed window): 1.80 s CPU / 2 s and 37k
// layout passes (transcript + PendingDot + DotMatrix), 1.83 s / 2 s and 39k (StatusVerb + thinking line + preview
// loop), 2.42 s / 2.5 s and 17k (MainWindow, reply pending); after: 0.01–0.02 s and 0–2 passes.
//   make test-unit FILTER=TranscriptIdleCostTests
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatHarness
import AntiChatStorage
import AppKit
import Darwin
import SwiftUI
import Testing
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct TranscriptIdleCostTests {
    struct Cost: CustomStringConvertible {
        var cpu: Double, layouts: Int, growthMB: Double
        var description: String { String(format: "cpu %.2f s, %d layouts, %+.1f MB", cpu, layouts, growthMB) }
    }

    nonisolated(unsafe) static var layouts = 0
    final class CountingHost<V: View>: NSHostingView<V> {
        override func layout() { TranscriptIdleCostTests.layouts += 1; super.layout() }
    }

    static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }

    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    private func window<V: View>(_ root: V, size: CGSize = CGSize(width: 800, height: 600)) -> NSWindow {
        _ = NSApplication.shared
        BackgroundRun.enable()
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: 80, y: 80), size: size), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = CountingHost(rootView: root)
        BackgroundRun.present(w)
        return w
    }

    /// Settles for `settle` s, then measures `seconds` of idling (async: scripted turns keep running beside it).
    private func measure(_ w: NSWindow, settle: Double = 0.5, seconds: Double = 2) async -> Cost {
        await pump(settle)
        Self.layouts = 0
        let c0 = Self.mainThreadCPU(), m0 = Self.footprintMB()
        await pump(seconds)
        return Cost(cpu: Self.mainThreadCPU() - c0, layouts: Self.layouts, growthMB: Self.footprintMB() - m0)
    }

    private func pump(_ s: Double) async {
        let end = Date().addingTimeInterval(s)
        while Date() < end { Self.spin(0.005); try? await Task.sleep(for: .milliseconds(2)) }
    }

    private func close(_ w: NSWindow) {
        w.contentView = nil
        w.close()
        Self.spin(0.05)
    }

    static let para = "Selectable assistant text that wraps across a couple of lines in the reading column of the transcript."

    private func expectIdle(_ cost: Cost, _ name: String, seconds: Double = 2) {
        print("TranscriptIdleCost \(name): \(cost)")
        #expect(cost.cpu < 0.25 * seconds, "\(name): \(cost)")
        #expect(cost.layouts < 200, "\(name): \(cost)")
        #expect(cost.growthMB < 20, "\(name): \(cost)")
    }

    struct Row: Identifiable, Equatable { let id: Int }

    /// The pulsing dot and the dot matrix under selectable text in the transcript's LazyVStack: animated, and idle.
    @Test func waitingTranscriptIsIdle() async {
        let rows = (0..<6).map(Row.init)
        let w = window(TranscriptList(items: rows, startDate: nil) { r in
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.para).textSelection(.enabled)
                if r.id == 4 { DotMatrixPlaceholder(animated: true).frame(width: 420, height: 280) }
                if r.id == 5 { PendingDot() }
            }
        }.environment(\.reduceMotionOverride, false))
        let cost = await measure(w)
        expectIdle(cost, "transcript + PendingDot + DotMatrix")
        // …and the animations do run (in Core Animation).
        let pulses = w.contentView.map { Self.find(PulsingDotLayer.PulsingDotView.self, in: $0) } ?? []
        let grids = w.contentView.map { Self.find(DotMatrixLayer.DotMatrixView.self, in: $0) } ?? []
        #expect(pulses.count == 1 && pulses.allSatisfy(\.isAnimating))
        #expect(grids.count == 1 && grids.allSatisfy(\.isAnimating))
        close(w)
    }

    /// The status line, the thinking line and the video preview loop: no sub-second SwiftUI clock. (A 0.25 s
    /// `.periodic` timeline measured 2.9 s CPU / 3 s and 137k layout passes here; 1 s: nothing.)
    @Test func statusLinesAndPreviewLoopAreIdle() async throws {
        let sent = Date().addingTimeInterval(-16)  // past the last verb change (14.5 s): a waiting line, no transition
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlecost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let frames = try (0..<4).map { i -> String in
            let img = NSImage(size: CGSize(width: 32, height: 32), flipped: false) { r in
                NSColor(calibratedHue: Double(i) / 4, saturation: 0.8, brightness: 0.8, alpha: 1).setFill(); r.fill(); return true
            }
            let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
            let url = dir.appendingPathComponent("f\(i).png")
            try rep.representation(using: .png, properties: [:])!.write(to: url)
            return url.path
        }
        let w = window(VStack(alignment: .leading, spacing: 12) {
            Text(Self.para).textSelection(.enabled)
            StatusVerbView(model: StatusLineModel(phase: .queued, hasContent: false, modelLoading: false), sentAt: sent)
            ReasoningDisclosure(reasoning: "Weighing the options", thinking: true, sentAt: sent, thoughtSeconds: nil)
            AnimatedPreview(frames: frames, aspect: 1.5, step: 1, total: 4)
        }.environment(\.reduceMotionOverride, false))
        let cost = await measure(w)
        expectIdle(cost, "StatusVerb + thinking line + preview loop")
        let loops = w.contentView.map { Self.find(FrameLoopLayer.FrameLoopView.self, in: $0) } ?? []
        #expect(loops.count == 1 && loops.allSatisfy { $0.isAnimating && $0.paths == frames })
        close(w)
    }

    /// The schedules wake exactly where the lines change.
    @Test func schedulesFollowTheLines() {
        let sent = Date(timeIntervalSince1970: 1_000)
        let model = StatusLineModel(phase: .queued, hasContent: false, modelLoading: false)
        let verb = Array(StatusVerbView.schedule(model, sentAt: sent).entries(from: sent, mode: .normal).prefix(10))
            .map { $0.timeIntervalSince(sent) }
        #expect(verb == [0, 2.5, 6.5, 10.5, 14.5], "\(verb)")
        let thinking = Array(ReasoningDisclosure.schedule(sentAt: sent).entries(from: sent.addingTimeInterval(0.3), mode: .normal).prefix(4))
            .map { $0.timeIntervalSince(sent) }
        #expect(thinking.map { ($0 * 10).rounded() / 10 } == [0.3, 2, 3, 4], "\(thinking)")
    }

    /// The real window: three turns, the last one pending (StatusVerb + PendingDot), Reduce Motion off.
    @Test func pendingReplyWindowIsIdle() async throws {
        let first = #"{"t":"textDelta","v":"A finished reply with **bold** and `code` that wraps in the column.","delayMs":1}"#
        let script = [first, #"{"t":"turn"}"#, first, #"{"t":"turn"}"#, #"{"t":"textDelta","v":"late","delayMs":60000}"#].joined(separator: "\n")
        let env = ChatEnvironment(database: try AppDatabase.inMemory(), engine: InProcessScriptedEngine(script: try EngineScript(text: script)),
                                  slot: { .scripted("inline") })
        let state = WindowState(service: ChatListService(environment: env), seed: 1)
        let sessions = ChatSessions(environment: env)
        let w = window(MainWindow(state: state, slots: sessions.slots).environment(\.reduceMotionOverride, false),
                       size: CGSize(width: 1180, height: 820))
        await pump(0.5)
        for text in ["one", "two", "three"] {
            sessions.currentChatID = state.currentChatID
            state.send(text, reduceMotion: false, turn: sessions.slots.startTurn)
            sessions.currentChatID = state.currentChatID
            await pump(1.5)
        }
        let m = sessions.model(for: try #require(state.currentChatID))
        #expect(m.messages.last?.status == .pending)
        // 7 s after the send: between the verb changes at 6.5 s and 10.5 s (each fades in once, motion.base).
        let cost = await measure(w, settle: 5.5, seconds: 2.5)
        expectIdle(cost, "MainWindow, reply pending", seconds: 2.5)
        close(w)
    }

    // MARK: fix/selection-hang-2 — the edit / versions path

    // Why the first harness missed r5's hang: it measured *clocks* (an idle transcript must not tick) at one window
    // size with overlay scrollers. The r4/r5 hangs are a self-sustaining layout loop with no clock: every hang sample
    // ran UserBubble's `onGeometryChange → rowWidth` action, i.e. the transcript column's width changed on every pass,
    // which happens only where that width is not pinned by the reading width (a column narrower than readingWidth +
    // padding) — and a legacy (space-taking) vertical scroller that comes and goes changes it. These cases sweep the
    // column width across that range, with legacy scrollers, over the image-edit transcript (picture, edit request,
    // edit job running, pending status) and with the viewer + version rail open over it.

    nonisolated(unsafe) static var beat = Date()
    nonisolated(unsafe) static var watchdogCase = ""
    static let watchdog: Void = {
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                guard !watchdogCase.isEmpty, Date().timeIntervalSince(beat) > 8 else { continue }
                // A stuck main thread cannot record an issue: say why, and end the run (test-unit's guard fails it).
                print("TranscriptIdleCost HANG: main thread stuck > 8 s in \(watchdogCase), footprint \(Int(footprintMB())) MB")
                exit(3)
            }
        }
    }()

    /// Legacy (always-visible, space-taking) scrollers, as with a mouse attached — the style the XCUITest Mac uses.
    static func useLegacyScrollers(_ on: Bool) {
        UserDefaults.standard.setVolatileDomain(on ? ["AppleShowScrollBars": "Always"] : [:], forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    static func picture(in dir: URL, _ name: String, hue: Double) throws -> String {
        let img = NSImage(size: CGSize(width: 384, height: 256), flipped: false) { r in
            NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.8, alpha: 1).setFill(); r.fill(); return true
        }
        let url = dir.appendingPathComponent(name)
        try NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: url)
        return url.path
    }

    enum EditRow: Identifiable, Equatable {
        case user(String), picture(String), text(String), editJob, pending
        var id: String {
            switch self {
            case .user(let t): "u-\(t)"
            case .picture(let p): "p-\(p)"
            case .text(let t): "t-\(t.prefix(12))"
            case .editJob: "job"
            case .pending: "pending"
            }
        }
    }

    @ViewBuilder static func editRow(_ r: EditRow) -> some View {
        switch r {
        case .user(let t): UserBubble(text: t)
        case .picture(let p): ImageResultCard(paths: [p], aspect: 1.5, promptUsed: "a lighthouse at dusk", onEdit: { _ in })
        case .text(let t): MessageMarkdownView(text: t, streaming: false)
        case .editJob: ImageJobCard(state: editJobState, promptUsed: "make the sky purple")
        case .pending:
            StatusVerbView(model: StatusLineModel(phase: .queued, hasContent: false, modelLoading: false),
                           sentAt: Date().addingTimeInterval(-16))
        }
    }

    /// The edit's job, generating (dot matrix + % pill + cancel).
    static let editJobState: ImageJobCardState = {
        var s = ImageJobCardState(job: "j2", aspect: 1.5, startedAt: Date())
        s.apply(MediaJobQueue.Update(job: "j2", state: .running, position: nil, progress: 0.4, previewPath: nil, resultPath: nil, errorCode: nil))
        return s
    }()

    /// One window per column width: settle, then 0.6 s must cost < 0.2 s of main-thread CPU (and never hang).
    private func sweep<V: View>(_ name: String, widths: StrideThrough<CGFloat>, height: CGFloat = 640,
                                _ root: @escaping () -> V) async -> [(CGFloat, Cost)] {
        _ = Self.watchdog
        var busy: [(CGFloat, Cost)] = []
        for width in widths {
            Self.watchdogCase = "\(name) width \(Int(width))"
            Self.beat = Date()
            let w = window(root(), size: CGSize(width: width, height: height))
            await pump(0.4)
            let widthChanges0 = TranscriptWidthWatch.changes
            let cost = await measure(w, settle: 0, seconds: 0.6)
            let widthChanges = TranscriptWidthWatch.changes - widthChanges0  // a settled column keeps its width
            if cost.cpu > 0.2 || widthChanges > 2 {
                print("TranscriptIdleCost \(name) width \(Int(width)): \(cost), column width changed \(widthChanges)×")
                busy.append((width, cost))
            }
            close(w)
        }
        Self.watchdogCase = ""
        print("TranscriptIdleCost \(name): \(busy.isEmpty ? "idle at every width" : "busy at \(busy.map { "\(Int($0.0)): \($0.1)" })")")
        return busy
    }

    @Test(arguments: [true, false]) func editPathTranscriptIsIdleAtEveryWidth(legacyScrollers: Bool) async throws {
        Self.useLegacyScrollers(legacyScrollers)
        defer { Self.useLegacyScrollers(false) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlecost-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = try Self.picture(in: dir, "v1.png", hue: 0.6)
        let rows: [EditRow] = [.user("Draw me a lighthouse at dusk"), .picture(v1),
                               .text("Here is a lighthouse at dusk, with the lamp just lit and the sky turning violet over the water."),
                               .user("Make the sky purple"), .editJob, .pending]
        // Column widths below and through readingWidth (760) + padding: the range where the scroller changes the width.
        let busy = await sweep("edit path, legacy scrollers \(legacyScrollers)", widths: stride(from: 520, through: 900, by: 6)) {
            TranscriptList(items: rows, startDate: nil) { Self.editRow($0) }
                .environment(\.reduceMotionOverride, false)
                .environment(\.readingWidth, 760)
        }
        #expect(busy.isEmpty, "busy at widths \(busy.map(\.0))")
    }

    @Test(arguments: [true, false]) func viewerWithVersionRailIsIdleAtEveryWidth(legacyScrollers: Bool) async throws {
        Self.useLegacyScrollers(legacyScrollers)
        defer { Self.useLegacyScrollers(false) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlecost-viewer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = try Self.picture(in: dir, "v1.png", hue: 0.6), v2 = try Self.picture(in: dir, "v2.png", hue: 0.8)
        let target = ImageViewerTarget(paths: [v2], selected: 0, artifactID: nil, current: v2,
                                       versions: [ImageVersionItem(n: 1, path: v1, operation: nil), ImageVersionItem(n: 2, path: v2, operation: "edit")])
        let rows: [EditRow] = [.user("Draw me a lighthouse at dusk"), .picture(v1), .user("Make the sky purple"), .picture(v2)]
        let busy = await sweep("viewer + version rail, legacy scrollers \(legacyScrollers)", widths: stride(from: 560, through: 900, by: 10)) {
            TranscriptList(items: rows, startDate: nil) { Self.editRow($0) }
                .overlay { ImageViewer(target: target, onEdit: { _ in }, onClose: {}) }
                .environment(\.reduceMotionOverride, false)
                .environment(\.readingWidth, 760)
        }
        #expect(busy.isEmpty, "busy at widths \(busy.map(\.0))")
    }

    /// The user bubble's row layout (no state): long text wraps at 70 % of the row, short text keeps its width, both
    /// at the trailing edge, on the first layout.
    @Test func userBubbleRowLayout() {
        let long = String(repeating: "a long request that wraps ", count: 12)
        for (row, text, wraps) in [(311.0, long, true), (900.0, long, true), (900.0, "Hi", false)] {
            let w = window(UserBubble(text: text).environment(\.readingWidth, 760).frame(width: row).fixedSize(horizontal: false, vertical: true),
                           size: CGSize(width: row, height: 900))
            w.contentView?.layoutSubtreeIfNeeded()
            Self.spin(0.05)
            let bubble = UIProbeRegistry.frame("userText", in: w)
            let maxBubble = UserBubble.maxBubbleWidth(readingWidth: 760, rowWidth: row)
            #expect(bubble != nil)
            if let b = bubble {
                #expect(b.width <= maxBubble + 0.5, "row \(row): bubble \(b.width) > \(maxBubble)")
                #expect(abs(b.maxX - row) < 1, "row \(row): bubble not at the trailing edge (\(b))")
                if wraps { #expect(b.width > maxBubble - 40, "row \(row): long text did not use the width (\(b.width) of \(maxBubble))") }
                else { #expect(b.width < 120) }
            }
            close(w)
        }
    }

    @MainActor @Observable final class ShownPicture {
        var image: NSImage
        var path: String
        init(_ image: NSImage, _ path: String) { self.image = image; self.path = path }
    }

    /// The viewer keeps the user's zoom when it is re-evaluated (a re-read of the same file is a new NSImage), and
    /// fits a new picture.
    @Test func viewerZoomSurvivesReEvaluation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("idlecost-zoom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p1 = try Self.picture(in: dir, "z1.png", hue: 0.3), p2 = try Self.picture(in: dir, "z2.png", hue: 0.7)
        let shown = ShownPicture(try #require(NSImage(contentsOfFile: p1)), p1)
        let w = window(ZoomHost(shown: shown), size: CGSize(width: 600, height: 400))
        Self.spin(0.3)
        let scroll = try #require(w.contentView.map { Self.find(NSScrollView.self, in: $0) }?.first { $0.allowsMagnification })
        scroll.magnification = 2
        shown.image = try #require(NSImage(contentsOfFile: p1))  // the same file, read again
        Self.spin(0.2)
        #expect(abs(scroll.magnification - 2) < 0.001, "re-evaluation reset the zoom to \(scroll.magnification)")
        shown.image = try #require(NSImage(contentsOfFile: p2))
        shown.path = p2
        Self.spin(0.2)
        let doc = try #require(scroll.documentView).frame.size, avail = scroll.contentSize
        #expect(abs(scroll.magnification - min(ZoomableImageView.maxFitMagnification,
                                               min(avail.width / doc.width, avail.height / doc.height))) < 0.01,
                "a new picture is shown fitted (\(scroll.magnification))")
        close(w)
    }

    /// Re-renders the ZoomableImageView from `shown` (the viewer's re-evaluation).
    struct ZoomHost: View {
        let shown: ShownPicture
        var body: some View { ZoomableImageView(image: shown.image, path: shown.path, command: nil) }
    }

    static func find<T: NSView>(_ type: T.Type, in v: NSView) -> [T] {
        (v as? T).map { [$0] } ?? [] + v.subviews.flatMap { find(type, in: $0) }
    }
}
}
