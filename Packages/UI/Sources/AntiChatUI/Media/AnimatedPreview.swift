// M5.T11 step 2 (R-041 AC4): the video job's live preview — the frames of the latest allowed step (each one written by
// the helper only after ChildSafetyCheck allowed it) play as a loop at 8 fps, at the clip's aspect, never smaller than
// 160 px on the short side. A new step replaces the set (the card updates every allowed step). A frame that cannot be
// read (deleted, partial, undecodable) is skipped; if none of the new set can be read the last good set stays (or the
// placeholder) — a preview failure never fails the job. Reduce Motion: the newest frame, still.
import AntiChatDesign
import AppKit
import SwiftUI

struct AnimatedPreview: View {
    let frames: [String]
    let aspect: CGFloat
    /// The step the shown frames belong to (VoiceOver value; 0 = none yet).
    var step: Int = 0
    var total: Int = 0
    var fps: Double = 8
    @EffectiveReduceMotion private var reduceMotion
    @State private var lastGood: [String] = []

    static let minSide: CGFloat = 160

    var body: some View {
        let shown = Self.displayed(frames, lastGood: lastGood)
        Group {
            if shown.isEmpty {
                DotMatrixPlaceholder(animated: !reduceMotion)
            } else if reduceMotion || shown.count == 1 {
                frame(shown[shown.count - 1])
            } else {
                // fix/selection-hang: a Core Animation loop, not a 1/8 s TimelineView (which kept the window's view
                // graph updating continuously while the job ran).
                FrameLoopLayer(paths: shown, images: shown.compactMap { PreviewFrameCache.image($0) }, fps: fps)
            }
        }
        .frame(minWidth: aspect >= 1 ? Self.minSide * aspect : Self.minSide,
               minHeight: aspect >= 1 ? Self.minSide : Self.minSide / max(aspect, 0.01))
        .onChange(of: frames, initial: true) { _, new in
            let ok = new.filter { PreviewFrameCache.image($0) != nil }
            if !ok.isEmpty { lastGood = ok }
        }
        // M5 review P2-6: a real label (and the step as the value), not a bare frame count.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(CopyKey("video.preview.a11y")))
        .accessibilityValue(Text(Self.accessibilityValue(step: step, total: total)))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("videoJob.preview")
    }

    /// "Step 3 of 8" once a step is known, else empty (the label alone).
    static func accessibilityValue(step: Int, total: Int) -> String {
        step > 0 && total > 0 ? CopyText(CopyKey("video.preview.a11yStep"), ["step": "\(step)", "total": "\(total)"]).string : ""
    }

    /// The readable frames of the newest set, else the last good set (a failed preview never blanks the card).
    static func displayed(_ frames: [String], lastGood: [String]) -> [String] {
        let loaded = frames.filter { PreviewFrameCache.image($0) != nil }
        return loaded.isEmpty ? lastGood : loaded
    }

    private func frame(_ path: String) -> some View {
        Group {
            if let img = PreviewFrameCache.image(path) {
                Image(nsImage: img).resizable().interpolation(.medium).scaledToFill()
            } else {
                Color.clear
            }
        }
    }
}

/// Decoded preview frames by path (small JPEGs, a few per step; the job's xfer dir is per job).
@MainActor
enum PreviewFrameCache {
    private static var images: [String: NSImage] = [:]
    private static var order: [String] = []
    static let limit = 64

    static func image(_ path: String) -> NSImage? {
        if let i = images[path] { return i }
        guard let data = FileManager.default.contents(atPath: path), let img = NSImage(data: data), img.isValid,
              img.size.width > 0 else { return nil }
        images[path] = img
        order.append(path)
        if order.count > limit { images[order.removeFirst()] = nil }
        return img
    }
}

/// Q-015 r4: finished pictures by path (the cards, the viewer's rail). `NSImage(contentsOfFile:)` in a view body made a
/// new image on every update of the reply, so SwiftUI decoded each full-size PNG again on every redraw of every card
/// in the turn (a reply's activity and progress updates redraw its rows many times a second). Keyed by path and
/// modification date, so a file rewritten in place is read again.
@MainActor
enum ResultImageCache {
    private static var images: [String: (date: Date?, image: NSImage)] = [:]
    private static var order: [String] = []
    static let limit = 24

    static func image(_ path: String) -> NSImage? {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = images[path], hit.date == date { return hit.image }
        guard let img = NSImage(contentsOfFile: path), img.isValid else { return nil }
        if images[path] == nil { order.append(path) }
        images[path] = (date, img)
        if order.count > limit { images[order.removeFirst()] = nil }
        return img
    }
}
