// Helper lifetime (architecture.md §4 process table, M1.T05 step 4): launchd starts AntiChatEngine.xpc on the
// first message; the helper exits `idleSeconds` (60 s) after the last session ended, once nothing is resident.
// While a model is still resident it re-checks every `idleSeconds` (keep-alive eviction is M2's scheduler).
import AntiChatFoundation
import Foundation

public actor HelperLifecycle {
    public nonisolated let idleSeconds: Double
    private let isIdle: @Sendable () async -> Bool
    private let exitProcess: @Sendable () -> Void
    public private(set) var sessions = 0
    private var timer: Task<Void, Never>?

    public init(
        idleSeconds: Double = 60, isIdle: @escaping @Sendable () async -> Bool,
        exitProcess: (@Sendable () -> Void)? = nil
    ) {
        self.idleSeconds = idleSeconds
        self.isIdle = isIdle
        self.exitProcess = exitProcess ?? { exit(0) }
    }

    /// Arms the idle timer at start (a helper nobody talks to does not linger).
    public func start() { if sessions == 0 { arm() } }

    public func sessionOpened() {
        sessions += 1
        timer?.cancel()
        timer = nil
    }

    public func sessionClosed() {
        sessions = max(0, sessions - 1)
        if sessions == 0 { arm() }
    }

    private func arm() {
        timer?.cancel()
        let wait = Duration.milliseconds(Int(idleSeconds * 1000))
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled, let self else { return }
                if await self.shouldExit() {
                    AppLog.log(.engine, .notice, "helper idle for \(self.idleSeconds) s with nothing resident: exiting")
                    self.exitProcess()
                    return
                }
            }
        }
    }

    private func shouldExit() async -> Bool {
        guard sessions == 0 else { return false }
        return await isIdle()
    }
}
