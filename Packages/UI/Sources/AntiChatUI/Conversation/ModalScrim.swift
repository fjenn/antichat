// VQ round 65 (S-09): the window dims under a conversation sheet (Versions, Report a problem). AppKit's own sheet
// shading barely darkened the window, so the sheet did not read as modal (the blind panel's "backdrop barely dims").
// The conversation column raises the flag; MainWindow draws one scrim over the whole window (sidebar and toolbar
// included), under the sheet's own window. Drawing only: it never takes a click.
import AntiChatDesign
import Observation
import SwiftUI

@MainActor
@Observable
final class ModalScrim {
    var isUp = false
}

extension EnvironmentValues {
    @Entry var modalScrim: ModalScrim? = nil
}

struct ModalScrimOverlay: View {
    let scrim: ModalScrim
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.black
            .opacity(scrim.isUp ? (colorScheme == .dark ? 0.45 : 0.22) : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.easeOut(duration: 0.15), value: scrim.isUp)
    }
}
