// M4.T08 (R-031, S-11, IS-8): the ImageJobCard's state machine (placeholder → waiting → loading → generating → done;
// blocked, failed, cancelled, lost) from queue updates, the settled card of a reloaded chat (from the call's result),
// and snapshots of every state, light/dark, 100/200 % text (Reduce Motion: static dots; the seconds read 0).
// Re-record: SNAPSHOT_TESTING_RECORD=all make test-unit FILTER=ImageJobCardTests.
import AntiChatHarness
import AntiChatStorage
import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import AntiChatDesign
@testable import AntiChatUI

extension WindowSuites {
@MainActor
@Suite(.serialized, .isolatedSettings) struct ImageJobCardTests {
    static func update(_ state: MediaJobState, progress: Double = 0, position: Int? = nil, preview: String? = nil,
                       result: String? = nil, code: String? = nil) -> MediaJobQueue.Update {
        MediaJobQueue.Update(job: "j1", state: state, position: position, progress: progress, previewPath: preview,
                             resultPath: result, errorCode: code)
    }

    /// M9.T05 P3: the pill's text advances with every helper step (`jobProgress` → queue update), previews or not
    /// (T1 sends none; a preview the gate withholds below 512 px arrives as a step without a path), and ticks each second.
    @Test func progressTextAdvancesEveryStep() {
        let start = Date(timeIntervalSince1970: 1_000)
        var s = ImageJobCardState(aspect: 1.5, startedAt: start)
        s.apply(Self.update(.running))
        var texts = [ProgressPill.text(percent: s.progress.percent, startedAt: start, at: start)]
        for step in 1...4 {
            s.apply(Self.update(.running, progress: Double(step) / 4, preview: nil))
            #expect(s.phase == .generating && s.previewPath == nil)
            texts.append(ProgressPill.text(percent: s.progress.percent, startedAt: start, at: start.addingTimeInterval(Double(step) * 4)))
        }
        #expect(texts == ["0% · 0 s", "25% · 4 s", "50% · 8 s", "75% · 12 s", "99% · 16 s"])
        // Between steps the seconds alone move the text.
        #expect(ProgressPill.text(percent: 25, startedAt: start, at: start.addingTimeInterval(5))
                != ProgressPill.text(percent: 25, startedAt: start, at: start.addingTimeInterval(6)))
    }

    @Test func stateMachine() {
        var s = ImageJobCardState(aspect: 1.5)
        #expect(s.phase == .placeholder && s.isActive)
        s.apply(Self.update(.queued, position: 2))
        #expect(s.phase == .waiting(position: 2))
        s.apply(Self.update(.running))
        #expect(s.phase == .loading, "running, no step yet: loading models (0 %)")
        s.apply(Self.update(.running, progress: 0.5))
        #expect(s.phase == .generating && s.progress.percent == 50)
        s.apply(Self.update(.running, progress: 1))
        #expect(s.progress.percent == 99, "100 only with the result")
        s.apply(Self.update(.done, progress: 1, result: "/tmp/r.png"))
        #expect(s.phase == .done(resultPath: "/tmp/r.png") && s.progress.percent == 100 && !s.isActive)
        for (st, want) in [(MediaJobState.blocked, ImageJobCardState.Phase.blocked), (.cancelled, .cancelled), (.lost, .lost),
                           (.failed, .failed(code: "sdJobFailed"))] {
            var t = ImageJobCardState(aspect: 1)
            t.apply(Self.update(st, code: "sdJobFailed"))
            #expect(t.phase == want)
        }
    }

    @Test func reloadedChatShowsTheStoredPicture() {
        let done = ToolActivity(id: "c1", tool: "create_image", state: .done, argumentsJSON: #"{"prompt":"p","aspect":"16:9"}"#,
                                result: ImageTurnPolicy.Outcome.done(imageID: "a1", width: 1344, height: 768, path: "/tmp/p.png").resultJSON)
        #expect(ImageJobActivity.settled(done)?.phase == .done(resultPath: "/tmp/p.png"))
        #expect(abs(ImageJobActivity.aspect(done) - 1344.0 / 768) < 0.001)
        let blocked = ToolActivity(id: "c2", tool: "create_image", state: .done, result: ImageTurnPolicy.Outcome.notShown.resultJSON)
        #expect(ImageJobActivity.settled(blocked)?.phase == .blocked)
        // M4.T16: missing detectors settle to the repair card with its size (was: no card at all).
        let missing = ToolActivity(id: "c4", tool: "create_image", state: .done,
                                   result: ImageTurnPolicy.Outcome.safetyMissing(sizeBytes: 1_234_000_000).resultJSON)
        #expect(ImageJobActivity.settled(missing)?.phase == .safetyMissing(sizeBytes: 1_234_000_000))
        let running = ToolActivity(id: "c3", tool: "create_image", state: .running, argumentsJSON: #"{"prompt":"p","aspect":"2:3"}"#)
        #expect(ImageJobActivity.settled(running)?.phase == .placeholder)
        #expect(abs(ImageJobActivity.aspect(running) - 2.0 / 3) < 0.001)
        #expect(ImageJobActivity.isImage(running) && !ImageJobActivity.isImage(ToolActivity(id: "x", tool: "web_search", state: .done)))
    }

    /// M4.T16 (Release run at T4): an edit's card followed its live job with aspect 1 (edit_image names none) and
    /// the 16:9 result drew 910 × 512, past the 760-pt transcript column. The card takes the result's aspect, and the
    /// picture never sizes the card even when the two disagree.
    @Test func editResultCardKeepsTheResultAspectAndTheMaxWidth() throws {
        let live = ImageJobCardState(aspect: 1)
        let edit = ToolActivity(id: "e1", tool: "edit_image", state: .done,
                                result: ImageTurnPolicy.Outcome.done(imageID: "a", width: 1024, height: 576, path: "/x.png").resultJSON)
        #expect(abs(ImageJobActivity.shown(live, edit).aspect - 1024.0 / 576) < 0.001)
        #expect(ImageJobActivity.shown(live, ToolActivity(id: "e2", tool: "edit_image", state: .running)).aspect == 1)

        let png = FileManager.default.temporaryDirectory.appendingPathComponent("wide-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 576, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        defer { try? FileManager.default.removeItem(at: png) }
        let size = NSHostingView(rootView: ImageResultCard(paths: [png.path], aspect: 1).frame(maxWidth: ImageJobCard.maxWidth)).fittingSize
        #expect(size.width <= ImageJobCard.maxWidth + 0.5 && size.height <= ImageJobCard.maxWidth + 0.5, "\(size)")
    }

    /// M4.T16 (Release run, Photo not installed): the pack-missing call is answered by the install card alone — no
    /// "couldn't be made" image card with Retry, and no "Skipped a repeated create_image call" line; a repeated call
    /// (duplicate notice) gets no second card either. A real failure still shows its card and line.
    @Test func skippedImageCallsGetNoCardAndPackMissingNoLine() {
        let missing = ToolActivity(id: "p1", tool: "create_image", state: .skipped, result: InstallCardPolicy.packNotInstalled)
        #expect(!ImageJobActivity.isImage(missing))
        #expect(ActivityLineView.isHidden(missing))
        let repeated = ToolActivity(id: "p2", tool: "edit_image", state: .skipped, result: ToolLoopPolicy.duplicateNotice)
        #expect(!ImageJobActivity.isImage(repeated))
        #expect(!ActivityLineView.isHidden(repeated))
        let failed = ToolActivity(id: "p3", tool: "create_image", state: .done, result: ImageTurnPolicy.Outcome.unavailable.resultJSON)
        #expect(ImageJobActivity.isImage(failed) && !ActivityLineView.isHidden(failed))
    }

    /// M4.T16 (real-model journey 5): a call that ended without a job (photo models not resolvable) or never queued
    /// one shows the error card with Retry within a bound — never "Creating image 0 %" counting up forever.
    @Test func callWithoutAJobNeverStaysAtZeroPercent() {
        let unavailable = ToolActivity(id: "u1", tool: "create_image", state: .done, result: ImageTurnPolicy.Outcome.unavailable.resultJSON)
        #expect(ImageJobActivity.settled(unavailable)?.phase == .failed(code: "unavailable"))
        #expect(ImageJobActivity.settled(unavailable)?.isActive == false)
        let failed = ToolActivity(id: "u2", tool: "create_image", state: .failed)
        #expect(ImageJobActivity.settled(failed)?.phase == .failed(code: "failed"))
        // Left without a job: an active placeholder becomes the not-started error; a settled card stays as it is.
        let placeholder = ImageJobCardState(aspect: 1)
        #expect(ImageJobActivityCard.unattached(placeholder)?.phase == .failed(code: MediaJobQueue.notStartedCode))
        var done = ImageJobCardState(aspect: 1)
        done.phase = .done(resultPath: "/tmp/r.png")
        #expect(ImageJobActivityCard.unattached(done)?.phase == .done(resultPath: "/tmp/r.png"))
        #expect(ImageJobActivityCard.attachTimeout <= .seconds(60))
    }

    static func gradient() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jobcard-\(UUID().uuidString).png")
        let ctx = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1),
                                                                                  CGColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 96, y: 64), options: [])
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url.path
    }

    @Test func snapshotsOfEveryState() throws {
        let png = try Self.gradient()
        // VQ r65: a fixed start and a frozen clock (mediaClockNow) at a plausible elapsed time per state (a picture takes
        // about 30 s here), never the "0 s" of a job started in the distant future.
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func state(_ phase: ImageJobCardState.Phase, percent: Double = 0, preview: String? = nil) -> ImageJobCardState {
            var s = ImageJobCardState(job: "j1", aspect: 1.5, startedAt: start)
            s.progress.observe(progress: percent)
            if case .done = phase { s.progress.finished() }
            s.previewPath = preview
            s.phase = phase
            return s
        }
        var lighter = state(.generating, percent: 0.25)
        lighter.lighterSetting = true
        let cases: [(String, ImageJobCardState)] = [
            ("placeholder", state(.placeholder)), ("waiting", state(.waiting(position: 2))), ("loading", state(.loading)),
            ("generating", state(.generating, percent: 0.5, preview: png)), ("done", state(.done(resultPath: png))),
            ("blocked", state(.blocked)), ("failed", state(.failed(code: "x"))), ("cancelled", state(.cancelled)),
            ("lost", state(.lost)), ("lighter", lighter),
            // vq/voice-mac-capture (S-11): the safety-missing card and the Photo-not-ready failure each have their own
            // message and action (not the generic failure).
            ("safetyMissing", state(.safetyMissing(sizeBytes: 12_400_000))), ("unavailable", state(.failed(code: "unavailable"))),
        ]
        for (name, s) in cases {
            for (label, scale) in [("100", CGFloat(1)), ("200", CGFloat(2))] {
                for look in ResponseActionsSnapshotTests.Look.allCases {
                    let v = ImageJobCard(state: s, promptUsed: "a lighthouse", onCancel: {}, onRetry: {})
                        .environment(\.reduceMotionOverride, true)
                        .environment(\.mediaClockNow, start.addingTimeInterval(2 + 0.3 * Double(s.progress.percent)))
                        .environment(\.chatTextScale, scale).dynamicTypeSize(scale > 1 ? .accessibility3 : .large)
                    assertSnapshot(of: ResponseActionsSnapshotTests.render(v, width: 420, look: look),
                                   as: .image(precision: 1, perceptualPrecision: 0.98), named: "\(name)-\(label)-\(look.rawValue)",
                                   testName: "imageJobCard")
                }
            }
        }
    }
}
}
