// M4.T12 step 3 (R-032 AC2; P-media-08): the viewer's zoom and pan — AppKit `NSScrollView.allowsMagnification`
// (pinch, ⌘+ / ⌘− through `ZoomCommand`, double-click to fit), the picture centred while it is smaller than the view.
import AppKit
import SwiftUI

/// A zoom request from the viewer's buttons / shortcuts (the counter makes repeated presses distinct).
struct ZoomCommand: Equatable {
    enum Kind: Equatable { case zoomIn, zoomOut, fit }
    var kind: Kind
    var serial: Int
}

struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    /// The picture's file: a new path is a new picture (shown fitted); the same path keeps the user's zoom and pan even
    /// if the view is re-evaluated or the file is re-read (fix/selection-hang-2: a fresh `NSImage` per evaluation
    /// failed the identity check below, so every re-evaluation re-set the image and re-fitted the zoom).
    var path: String? = nil
    let command: ZoomCommand?
    /// Reports the magnification (tests and the accessibility value).
    var onMagnification: ((CGFloat) -> Void)?

    static let minMagnification: CGFloat = 0.05
    static let maxMagnification: CGFloat = 8
    static let step: CGFloat = 1.25

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FittingScrollView()
        scroll.contentView = CenteringClipView()
        scroll.allowsMagnification = true
        scroll.minMagnification = Self.minMagnification
        scroll.maxMagnification = Self.maxMagnification
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let imageView = DoubleClickImageView()
        imageView.imageScaling = .scaleAxesIndependently
        imageView.onDoubleClick = { [weak scroll] in scroll.map(Self.fit) }
        scroll.documentView = imageView
        context.coordinator.scroll = scroll
        context.coordinator.observe(scroll) { onMagnification?($0) }
        context.coordinator.shownPath = path
        setImage(scroll)
        DispatchQueue.main.async { Self.fit(scroll) }
        scroll.setAccessibilityIdentifier("imageViewer.zoom")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let shown = (scroll.documentView as? NSImageView)?.image
        if let path, path != context.coordinator.shownPath {  // another picture: show it whole
            context.coordinator.shownPath = path
            setImage(scroll)
            Self.fit(scroll)
        } else if path == nil, shown !== image {  // no path to compare: identity (callers without a file)
            setImage(scroll)
            Self.fit(scroll)
        } else if shown !== image {  // the same picture, re-read: swap it in place, zoom and pan kept
            (scroll.documentView as? NSImageView)?.image = image
        }
        guard let command, command != context.coordinator.lastCommand else { return }
        context.coordinator.lastCommand = command
        switch command.kind {
        case .zoomIn: Self.zoom(scroll, by: Self.step)
        case .zoomOut: Self.zoom(scroll, by: 1 / Self.step)
        case .fit: Self.fit(scroll)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func setImage(_ scroll: NSScrollView) {
        guard let view = scroll.documentView as? NSImageView else { return }
        view.image = image
        let size = image.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        view.frame = NSRect(origin: .zero, size: size.width > 0 ? size : image.size)
        (scroll as? FittingScrollView)?.autoFit = true
    }

    static func zoom(_ scroll: NSScrollView, by factor: CGFloat) {
        (scroll as? FittingScrollView)?.autoFit = false
        let center = NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY)
        scroll.setMagnification(min(maxMagnification, max(minMagnification, scroll.magnification * factor)), centeredAt: center)
    }

    /// Fit never enlarges a picture past this (a tiny picture is not blown up into a blur).
    static let maxFitMagnification: CGFloat = 4

    /// Whole picture in view, filling it (vq/voice-mac-capture, S-13: a picture smaller than the window drew at its
    /// pixel size in a large empty canvas; the viewer now fits it like Preview's Zoom to Fit, up to 400 %).
    static func fit(_ scroll: NSScrollView) {
        guard let doc = scroll.documentView, doc.frame.width > 0, doc.frame.height > 0 else { return }
        let avail = scroll.contentSize
        guard avail.width > 0, avail.height > 0 else { return }
        let m = min(maxFitMagnification, min(avail.width / doc.frame.width, avail.height / doc.frame.height))
        let fitting = scroll as? FittingScrollView
        fitting?.autoFit = true
        let target = max(minMagnification, m)
        guard abs(scroll.magnification - target) > 0.0005 else { return }  // layout() calls this: no relayout loop
        fitting?.isFitting = true
        scroll.magnification = target
        fitting?.isFitting = false
        fitting?.autoFit = true
    }

    final class Coordinator {
        weak var scroll: NSScrollView?
        var lastCommand: ZoomCommand?
        var shownPath: String?
        private var token: NSObjectProtocol?

        func observe(_ scroll: NSScrollView, _ report: @escaping (CGFloat) -> Void) {
            token = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: scroll,
                                                           queue: .main) { [weak scroll] _ in scroll.map { report($0.magnification) } }
        }

        deinit { token.map(NotificationCenter.default.removeObserver) }
    }
}

/// Stays fitted while its size changes (window resize, first layout) until the user zooms; any magnification set from
/// outside a fit (pinch, ⌘+/⌘−, a caller) ends the auto-fit.
final class FittingScrollView: NSScrollView {
    var autoFit = true
    var isFitting = false

    override var magnification: CGFloat {
        didSet { if !isFitting { autoFit = false } }
    }

    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        autoFit = false
        super.setMagnification(magnification, centeredAt: point)
    }

    override func magnify(with event: NSEvent) {
        autoFit = false
        super.magnify(with: event)
    }

    override func layout() {
        super.layout()
        if autoFit { ZoomableImageView.fit(self) }
    }
}

/// Keeps the document centred while it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

final class DoubleClickImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() } else { super.mouseDown(with: event) }
    }
}
