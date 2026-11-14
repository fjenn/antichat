// Isolation audit (docs/prd/reviews/isolation-audit.md): completion handlers that AppKit's NSWorkspace calls on its
// own queues. `openApplication(at:configuration:completionHandler:)` calls back on a private concurrent queue. A
// closure literal written inside a @MainActor function is main-actor isolated, so Swift 6's runtime isolation check
// traps on entry (EXC_BREAKPOINT in `_dispatch_assert_queue_fail`, the P74 MCP sign-in crash class) when the framework
// calls it off the main thread. These closures are built here, outside any actor: explicitly @Sendable, they only hop
// `action` to the main actor.
import AppKit

enum WorkspaceCompletion {
    /// A nonisolated NSWorkspace completion (`openApplication` / `recycle`; `Value` is the app or the moved URLs) that
    /// runs `action` with the error on the main actor, whatever queue NSWorkspace calls it on.
    nonisolated static func onMain<Value>(
        _ action: @escaping @MainActor @Sendable ((any Error)?) -> Void
    ) -> @Sendable (Value, (any Error)?) -> Void {
        { _, error in
            DispatchQueue.main.async { MainActor.assumeIsolated { action(error) } }
        }
    }
}
