// Every popover and menu card in the app sits on the opaque raised surface. The platform's popover material is
// translucent, so sidebar and transcript text showed through the cards.
import SwiftUI

public extension View {
    /// The content of a `.popover`: an opaque `surface.raised` ground, under the arrow too.
    func popoverSurface() -> some View {
        background(Color.surfaceRaised).presentationBackground(Color.surfaceRaised)
    }
}
