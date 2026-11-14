// fix/selection-hang: the transcript's always-on animations (the "Thinking…" PendingDot pulse, the picture card's
// dot-matrix placeholder) run in Core Animation, not in SwiftUI. A SwiftUI `repeatForever` / `phaseAnimator` /
// `TimelineView(.animation)` makes the window's view graph update every display frame for as long as the reply or the
// picture job waits; each of those transactions also re-placed the transcript's LazyVStack, re-updated every
// selectable Text's SelectionOverlay platform view and ran a hover update, so the main thread did a full transcript
// layout per frame (XCUITest round 4: "main thread busy 30 s", footprint 39 MB → 1.3 GB). A layer animation is
// rendered by the render server: no SwiftUI transaction, no layout, nothing on the main thread per frame.
import AntiChatDesign
import AppKit
import QuartzCore
import SwiftUI

/// A dot pulsing in opacity and scale (`motion.pending.pulse`), as a Core Animation layer animation.
struct PulsingDotLayer: NSViewRepresentable {
    let animated: Bool

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView() }

    func updateNSView(_ v: PulsingDotView, context: Context) {
        if v.animated != animated { v.animated = animated }  // the StatusVerb timeline re-runs this 4×/s: no-op then
    }

    final class PulsingDotView: NSView {
        static let key = "pendingPulse"
        let dot = CALayer()
        var animated = true { didSet { updateAnimation() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(dot)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.backgroundColor = NSColor.textPrimary.cgColor  // resolved in the view's effective appearance
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = min(bounds.width, bounds.height)
            dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            dot.cornerRadius = side / 2
            dot.position = CGPoint(x: bounds.midX, y: bounds.midY)  // anchor (0.5, 0.5): scales about its centre
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateAnimation()
        }

        var isAnimating: Bool { dot.animation(forKey: Self.key) != nil }

        func updateAnimation() {
            guard animated, window != nil else {
                dot.removeAnimation(forKey: Self.key)
                return
            }
            guard !isAnimating else { return }
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 1
            opacity.toValue = 0.35
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1
            scale.toValue = 0.8
            let group = CAAnimationGroup()
            group.animations = [opacity, scale]
            group.duration = MotionToken.pendingPulse.duration / 2
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.isRemovedOnCompletion = false
            dot.add(group, forKey: Self.key)
        }
    }
}

/// The video job's preview loop (AnimatedPreview): the frames as a discrete `contents` keyframe animation at `fps`,
/// aspect-fill — formerly a 1/8 s `TimelineView` that swapped an `Image` through SwiftUI eight times a second.
struct FrameLoopLayer: NSViewRepresentable {
    let paths: [String]
    let images: [NSImage]
    let fps: Double

    func makeNSView(context: Context) -> FrameLoopView { FrameLoopView() }

    func updateNSView(_ v: FrameLoopView, context: Context) { v.show(paths: paths, images: images, fps: fps) }

    final class FrameLoopView: NSView {
        static let key = "frameLoop"
        private(set) var paths: [String] = []
        private var fps: Double = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
            layer?.masksToBounds = true
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        var isAnimating: Bool { layer?.animation(forKey: Self.key) != nil }

        func show(paths: [String], images: [NSImage], fps: Double) {
            guard paths != self.paths || fps != self.fps, let layer else { return }
            self.paths = paths
            self.fps = fps
            let cgs = images.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }
            layer.removeAnimation(forKey: Self.key)
            layer.contents = cgs.last
            guard cgs.count > 1, fps > 0 else { return }
            let loop = CAKeyframeAnimation(keyPath: "contents")
            loop.values = cgs
            loop.calculationMode = .discrete
            loop.duration = Double(cgs.count) / fps
            loop.repeatCount = .infinity
            loop.isRemovedOnCompletion = false
            layer.add(loop, forKey: Self.key)
        }
    }
}

/// The picture card's drifting dot grid (DotMatrixPlaceholder, animated): one dot layer replicated across a row
/// and the row across the grid, each copy's opacity wave delayed by its column and row — the same
/// `0.12 + 0.18 · (sin(0.55·c + 0.35·r − 2.2·t) + 1) / 2` the static Canvas draws at t = 0.
struct DotMatrixLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> DotMatrixView { DotMatrixView() }
    func updateNSView(_ v: DotMatrixView, context: Context) {}

    final class DotMatrixView: NSView {
        static let key = "dotWave"
        static let spacing = DotMatrixPlaceholder.spacing
        static let omega = 2.2
        let rows = CAReplicatorLayer()
        let columns = CAReplicatorLayer()
        let dot = CALayer()
        private var grid = (cols: 0, rows: 0)

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            columns.addSublayer(dot)
            rows.addSublayer(columns)
            layer?.addSublayer(rows)
            layer?.masksToBounds = true
            dot.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
            dot.cornerRadius = 1.5
            dot.opacity = 0.21
            // sin(0.55c − 2.2t) = sin(−2.2(t − 0.25c)): column c runs 0.25 s behind column 0; row r 0.159 s.
            columns.instanceDelay = 0.55 / Self.omega
            columns.instanceTransform = CATransform3DMakeTranslation(Self.spacing, 0, 0)
            rows.instanceDelay = 0.35 / Self.omega
            rows.instanceTransform = CATransform3DMakeTranslation(0, Self.spacing, 0)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }

        override func updateLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dot.backgroundColor = NSColor.textSecondary.cgColor
            CATransaction.commit()
        }

        override func layout() {
            super.layout()
            let cols = Int(bounds.width / Self.spacing), rowCount = Int(bounds.height / Self.spacing)
            guard (cols, rowCount) != grid else { return }
            grid = (cols, rowCount)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            columns.instanceCount = max(cols, 0)
            rows.instanceCount = max(rowCount, 0)
            columns.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.spacing)
            rows.frame = bounds
            dot.position = CGPoint(x: Self.spacing / 2, y: Self.spacing / 2)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { dot.removeAnimation(forKey: Self.key); return }
            guard dot.animation(forKey: Self.key) == nil else { return }
            let period = 2 * Double.pi / Self.omega
            let steps = 24
            let wave = CAKeyframeAnimation(keyPath: "opacity")
            wave.values = (0...steps).map { i -> Double in
                let t = period * Double(i) / Double(steps)
                return 0.12 + 0.18 * (sin(-Self.omega * t) + 1) / 2
            }
            wave.duration = period
            wave.repeatCount = .infinity
            wave.calculationMode = .linear
            wave.isRemovedOnCompletion = false
            // Started a full grid's delay in the past, so every copy is already moving when it first shows.
            wave.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil) - 60
            wave.fillMode = .backwards
            dot.add(wave, forKey: Self.key)
        }

        var isAnimating: Bool { dot.animation(forKey: Self.key) != nil }
    }
}
