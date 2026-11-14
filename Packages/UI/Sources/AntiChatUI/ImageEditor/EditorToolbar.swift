// M4.T15 step 1 (R-034 AC1/AC5, S-13): the editor toolbar along the bottom of the viewer — Erase (mask brush), Remove
// background, and Describe the change (M4.T13). Markup, Sketch, Comment pins and Resize moved to M11 (D-026).
//   * Remove background: one click → a `local` job (Vision) → the result is the picture's next version, shown at once.
//   * Erase: the picture switches to fit-to-window with a brush overlay (three sizes); paint the area, then Erase
//     sends the 8-bit mask (MaskBrush, feather 4 px) → a `local` job (LaMa + MaskCompositor) → the next version.
//   * While a job runs the tools are disabled and a spinner shows; a withheld picture (ChildSafetyCheck) shows only the
//     bare blocked line (no detail, D-006); no subject → `editor.removeBg.none`.
import AntiChatDesign
import SwiftUI

/// A direct editor action on the shown picture.
public struct LocalEditRequest: Sendable, Equatable {
    public enum Operation: String, Sendable { case removeBackground, erase }
    public var sourceID: String
    public var operation: Operation
    /// Erase: the 8-bit mask PNG at the picture's pixel size (white = erase).
    public var mask: Data?
    public init(sourceID: String, operation: Operation, mask: Data? = nil) {
        self.sourceID = sourceID; self.operation = operation; self.mask = mask
    }
}

public enum LocalEditOutcome: Sendable, Equatable {
    /// The new version (its file) and the artifact's refreshed chain (oldest first).
    case done(path: String, versions: [ImageVersionItem])
    case noSubject
    case notShown
    /// M4 review P2-5 (R-285 AC6): the ChildSafetyCheck files are missing or damaged (the repair card, this size).
    case safetyMissing(sizeBytes: Int64)
    case failed
}

struct EditorToolbar: View {
    let busy: Bool
    let erasing: Bool
    let canErase: Bool
    let onErase: () -> Void
    let onRemoveBackground: () -> Void
    let onApplyErase: () -> Void
    let onCancelErase: () -> Void
    @Binding var brush: Int

    var body: some View {
        HStack(spacing: Spacing.space2) {
            if erasing {
                Text(CopyKey("editor.brushSize")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                Picker(selection: $brush) {
                    ForEach(MaskBrush.radii.indices, id: \.self) { i in
                        Circle().frame(width: CGFloat(6 + 4 * i), height: CGFloat(6 + 4 * i)).tag(i)
                    }
                } label: { Text(CopyKey("editor.brushSize")) }
                    .pickerStyle(.segmented).accentFilledSegments().labelsHidden().frame(width: 120)
                    .accessibilityIdentifier("editor.brushSize")
                Spacer().frame(width: Spacing.space2)
                Button(action: onCancelErase) { Text(CopyKey("editor.cancel")) }
                    .controlSize(.small)
                    .accessibilityIdentifier("editor.erase.cancel")
                Button(action: onApplyErase) { Text(CopyKey("editor.erase")) }
                    .controlSize(.small).buttonStyle(PrimaryButtonStyle())
                    .disabled(!canErase || busy)
                    .accessibilityIdentifier("editor.erase.apply")
            } else {
                tool("eraser", CopyKey("editor.erase"), id: "editor.erase", action: onErase)
                tool("person.crop.rectangle.badge.plus", CopyKey("editor.removeBg"), id: "editor.removeBg", action: onRemoveBackground)
            }
            if busy {
                ProgressView().controlSize(.small).accessibilityIdentifier("editor.busy")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editorToolbar")
    }

    private func tool(_ symbol: String, _ key: CopyKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(key) } icon: { Image(systemName: symbol) }
                .labelStyle(.titleAndIcon)
                .typeStyle(.footnote)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.space2)
                .frame(height: 28)
                .background(Capsule().fill(Color.surfaceRaised))
                .overlay { Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control) }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(key.string())
        .accessibilityIdentifier(id)
    }
}

/// Erase mode: the picture fitted to the view with the brush overlay; strokes in normalised picture coordinates.
struct MaskCanvas: View {
    let image: NSImage
    @Binding var strokes: [MaskStroke]
    let radius: CGFloat
    @State private var live: MaskStroke?

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fitted(image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                Canvas { ctx, _ in
                    for s in strokes + (live.map { [$0] } ?? []) {
                        let w = 2 * s.radius * max(rect.width, rect.height)
                        var path = Path()
                        let pts = s.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
                        if pts.count == 1 {
                            path.addEllipse(in: CGRect(x: pts[0].x - w / 2, y: pts[0].y - w / 2, width: w, height: w))
                            ctx.fill(path, with: .color(Color.accentColor.opacity(0.45)))
                        } else {
                            path.addLines(pts)
                            ctx.stroke(path, with: .color(Color.accentColor.opacity(0.45)),
                                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let p = CGPoint(x: (g.location.x - rect.minX) / max(1, rect.width), y: (g.location.y - rect.minY) / max(1, rect.height))
                let q = CGPoint(x: min(1, max(0, p.x)), y: min(1, max(0, p.y)))
                if live == nil { live = MaskStroke(points: [q], radius: radius) } else { live?.points.append(q) }
            }.onEnded { _ in
                if let live { strokes.append(live) }
                live = nil
            })
        }
        .accessibilityElement()
        .accessibilityLabel(Text(CopyKey("editor.erase")))
        .accessibilityIdentifier("editor.maskCanvas")
    }

    /// The aspect-fit rect of `size` inside `bounds` (centred).
    static func fitted(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let k = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * k, h = size.height * k
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}
