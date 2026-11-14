// fix/selection-hang: one window's model objects, created once per window. A `WindowGroup` re-evaluates its content
// (and so the host view's `init`) whenever anything it reads changes; `@State(initialValue: ChatSessions(…))` built a
// new ChatSessions + WindowState on every such pass — State kept the first and dropped the rest, but each one had
// already registered NotificationCenter observers and started its work. A stuck app (5.3 GB, main thread 100 %) spent
// every transaction in `MainWindowHost.init → ChatSessions.init → addObserver`. `@StateObject`'s initial value is an
// autoclosure SwiftUI evaluates only when the view's identity is new, so a re-evaluation creates nothing.
import SwiftUI

@MainActor
public final class WindowOwner<Objects>: ObservableObject {
    public let objects: Objects

    public init(_ make: () -> Objects) {
        objects = make()
    }
}
