// M5.T10 step 3 (R-043 AC1): Animate (`video.animate`) on an image result card — in its ⋯ menu and as a hover action
// on the finished picture. A click asks for image-to-video of that picture: the window sends "Animate" with the Create
// video tool forced and the picture's artifact id as `source_image_id` (ChatSessions.animate → one-shot chips
// `video` + `animate:<id>`, VideoRoute), so the plan card opens with the explicit intent (countdown allowed, R-290
// AC2). No check runs on the source picture (D-005, R-043 AC2); the clip passes the gate like every video (M5.T06).
// The window injects the action only while video can run here (ComposerMenuContext.videoAvailable).
import AntiChatDesign
import SwiftUI

/// Animate a picture of the shown chat (an artifact or attachment id).
public struct AnimateImageAction: Sendable {
    let run: @MainActor @Sendable (String) -> Void
    public init(_ run: @escaping @MainActor @Sendable (String) -> Void) { self.run = run }
    @MainActor public func callAsFunction(_ imageRef: String) { run(imageRef) }
}

extension EnvironmentValues {
    /// nil = Animate is not offered (video not installed / off / this Mac is ineligible).
    @Entry public var animateImage: AnimateImageAction? = nil
}

/// The hover action on a finished picture.
struct ImageAnimateHoverButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label { Text(CopyKey("video.animate")) } icon: { Image(systemName: "film") }
                .typeStyle(.caption)
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, Spacing.space2)
                .frame(height: 24)
                .background(Capsule().fill(Color.surfaceRaised.opacity(0.92)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(CopyKey("video.animate").string())
        .accessibilityIdentifier("imageJobCard.animateHover")
    }
}
