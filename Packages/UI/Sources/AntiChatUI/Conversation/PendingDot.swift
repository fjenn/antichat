// PendingDot (components.md §3): 8 pt `text.primary` dot, pulsing (`motion.pending.pulse`, 1.2 s loop);
// Reduce Motion → static. Appears in the same frame as the user bubble (IS-1, NFR-U2).
// fix/selection-hang: the pulse is a Core Animation layer animation (PulsingDotLayer), not a SwiftUI `repeatForever`
// — a SwiftUI animation that never ends updated the whole window's view graph every frame while a reply waited.
import AntiChatDesign
import SwiftUI

public struct PendingDot: View {
    @EffectiveReduceMotion private var reduceMotion

    public init() {}

    public var body: some View {
        Group {
            if reduceMotion {
                Circle().fill(Color.textPrimary)
            } else {
                PulsingDotLayer(animated: true)
            }
        }
        .frame(width: 8, height: 8)
        // Q-015 r4: named "Thinking…" (it had no name). The pulse is a Core Animation layer (selection hang): a SwiftUI
        // repeatForever kept the window's view graph updating every frame.
        .accessibilityElement()
        .accessibilityLabel(Text(CopyKey("status.thinking")))
        .accessibilityIdentifier("pendingDot")
    }
}

#Preview("PendingDot") {
    PendingDot().padding(Spacing.space7).background(Color.surfaceCanvas)
}
