// Universal interaction states (components.md "Universal states"; M1.T03 step 4).
import SwiftUI

/// The pointer/keyboard state a component draws. Live UI derives it from hover, press and focus; previews and
/// snapshot tests pin it with `.interactionState(_:)` so every state in components.md can be rendered.
public enum InteractionState: String, CaseIterable, Sendable {
    case `default`, hover, pressed, focused
}

public extension EnvironmentValues {
    /// Pinned state for previews/snapshots; `nil` in the running app.
    @Entry var pinnedInteractionState: InteractionState? = nil
}

public extension View {
    /// Pins the interaction state of the base components inside (previews, snapshot tests).
    func interactionState(_ state: InteractionState?) -> some View {
        environment(\.pinnedInteractionState, state)
    }

    /// components.md "focused": `focus.ring` 3 pt with a 1 pt outer offset, around a shape of `cornerRadius`.
    func focusRing(_ visible: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            if visible {
                Group {
                    if cornerRadius >= Radius.pill {
                        Capsule(style: .circular).strokeBorder(Color.focusRing, lineWidth: Stroke.focus)
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius + Stroke.focusOffset + Stroke.focus / 2,
                                         style: .continuous)
                            .strokeBorder(Color.focusRing, lineWidth: Stroke.focus)
                    }
                }
                .padding(-(Stroke.focusOffset + Stroke.focus))
                .allowsHitTesting(false)
            }
        }
    }
}

/// Resolves the effective state from live inputs, unless pinned.
struct ResolvedInteraction {
    let pinned: InteractionState?
    let hovering: Bool
    let pressed: Bool
    let focused: Bool

    var state: InteractionState {
        if let pinned { return pinned }
        if pressed { return .pressed }
        if focused { return .focused }
        if hovering { return .hover }
        return .default
    }
}
