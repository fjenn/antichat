// M4.T08 step 1–2 (S-11): the image job card's placeholder.
import AntiChatDesign
import SwiftUI

/// The placeholder: a grid of dots whose brightness drifts (static under Reduce Motion, where the % pill and seconds
/// still change every second). fix/selection-hang: the drift is a Core Animation layer animation (DotMatrixLayer); the
/// former `TimelineView(.animation)` re-ran this Canvas — and updated the window's view graph — every display frame for
/// as long as the job ran.
struct DotMatrixPlaceholder: View {
    let animated: Bool
    static let spacing: CGFloat = 14

    var body: some View {
        Group {
            if animated {
                DotMatrixLayer()
            } else {
                Canvas { g, size in Self.draw(g, size: size) }
            }
        }
        .accessibilityHidden(true)
    }

    /// The still grid (t = 0): what Reduce Motion and the snapshots show.
    static func draw(_ g: GraphicsContext, size: CGSize) {
        let cols = Int(size.width / spacing), rows = Int(size.height / spacing)
        guard cols > 0, rows > 0 else { return }
        for r in 0..<rows {
            for c in 0..<cols {
                let phase = sin(Double(c) * 0.55 + Double(r) * 0.35)
                let a = 0.12 + 0.18 * (phase + 1) / 2
                let x = (CGFloat(c) + 0.5) * spacing, y = (CGFloat(r) + 0.5) * spacing
                g.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)), with: .color(Color.textSecondary.opacity(a)))
            }
        }
    }
}
