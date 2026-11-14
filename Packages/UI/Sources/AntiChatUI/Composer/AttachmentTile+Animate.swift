// M5.T10 step 3 (R-043 AC1): Animate (`video.animate`) on an image tile in the composer tray. A click sends the
// message now with the Create video tool forced and this picture as the image-to-video source (one-shot chips
// `video` + `animate:<attachment id>`, VideoRoute), so the plan card opens with `source_image_id` set and the
// explicit intent (the countdown is allowed, R-290 AC2). The picture itself is never checked (D-005, R-043 AC2).
import AntiChatDesign
import AntiChatHarness
import AntiChatKnowledge
import SwiftUI

extension AttachmentTileView {
    /// Animate is offered on a ready image tile with a stored attachment row, when video can run here.
    static func offersAnimate(_ item: IntakeItem?, videoAvailable: Bool) -> Bool {
        guard videoAvailable, let item, item.state == .ready, item.attachmentID != nil else { return false }
        return item.kind.isImage
    }
}

/// The hover button on an image tile (and its accessibility action).
struct AttachmentAnimateButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(CopyKey("video.animate")) } icon: { Image(systemName: "film") }
                .labelStyle(.iconOnly)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.surfaceRaised.opacity(0.92)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(CopyKey("video.animate").string())
        .accessibilityLabel(Text(CopyKey("video.animate")))
        .probeID("fileTileAnimate")
    }
}
