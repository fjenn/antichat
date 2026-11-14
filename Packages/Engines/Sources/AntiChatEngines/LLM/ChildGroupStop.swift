// fix/soak-engine (M9.T06 dry run, llama-server SIGBUS at shutdown): the one graceful stop of a supervised child's
// process group — exactly ONE SIGTERM, a grace period, then SIGKILL.
//
// Why not swift-subprocess's teardown: cancelling the task that runs `Subprocess.run` starts TWO teardown sequences in
// swift-subprocess 1.0.2 — `withAsyncTaskCleanupHandler`'s `onCleanup` (Configuration.swift:182) and the `catch` of the
// body, which throws CancellationError from our `ProcessExit.wait` (Configuration.swift:157). Each sends SIGTERM to the
// group, so the child got two SIGTERMs a few ms apart. llama-server's handler (tools/server/server.cpp:29-38, b12254 and
// upstream master) answers a second SIGINT/SIGTERM with `exit(1)` from inside the handler, on whatever thread took the
// signal, while the main thread is still shutting down: `exit` runs the static destructors (the Metal device list,
// `ggml_metal_rsets_free` → GGML_ASSERT abort) under `common_memory_breakdown_print`, which then reads freed backend
// state (EXC_ARM_DA_ALIGN: a branch through a freed pointer; KERN_INVALID_ADDRESS; or SIGABRT from the destructor).
// All 24 llama-server crash reports on the dev Mac (b11669 and b12254) carry `signal_handler → exit` on one thread.
// Upstream issue ggml-org/llama.cpp#29581 (open, no fix merged as of 2026-11-12) is the same race.
//
// The supervisors therefore never cancel the run task to stop the child: they call `terminate`, the child exits on its
// own, the run body (`ProcessExit.wait`) returns and swift-subprocess reaps it. The teardown sequence stays configured
// only as the fallback for a cancellation nobody planned.
import Darwin
import Foundation

public enum ChildGroupStop {
    public enum Outcome: String, Sendable, Equatable {
        /// Nothing to signal: the leader had already exited (or is not our unreaped child).
        case alreadyExited
        /// Exited within the grace period after the one SIGTERM.
        case exitedOnTerm
        /// Still running at the end of the grace period: the group got SIGKILL.
        case killed
    }

    /// Default grace period: the 3 s of the supervisors' former teardown sequence (llama-server frees a 9B model's
    /// Metal buffers in well under a second).
    public static let defaultGrace: Duration = .seconds(3)

    /// Stops the process group led by `leader` (an unreaped child of this process that leads its own group, as with
    /// `processGroupID = 0`): SIGTERM once, SIGCONT (a stopped group handles the SIGTERM), wait ≤ `grace` for the leader
    /// to exit, else SIGKILL the group. Never reaps (the run task does) and runs to completion even when the calling
    /// task is cancelled (a half-done stop would leave the child alive or signal it twice).
    @discardableResult
    public static func terminate(leader: pid_t, grace: Duration = defaultGrace, poll: Duration = .milliseconds(20),
                                 signal send: @escaping @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) }) async -> Outcome {
        await Task.detached { await ChildGroupStop.run(leader: leader, grace: grace, poll: poll, send: send) }.value
    }

    static func run(leader: pid_t, grace: Duration, poll: Duration, send: @Sendable (pid_t, Int32) -> Int32) async -> Outcome {
        // `isUnreaped` first: a reaped leader's pid (and so its group id) may already belong to someone else.
        guard leader > 1, OwnChild.isUnreaped(leader), !OwnChild.hasExited(leader) else { return .alreadyExited }
        _ = send(-leader, SIGTERM)
        _ = send(-leader, SIGCONT)
        let deadline = ContinuousClock.now + grace
        while ContinuousClock.now < deadline {
            if OwnChild.hasExited(leader) { return .exitedOnTerm }
            try? await Task.sleep(for: poll)
        }
        // Still our live child (unreaped, not exited) = its group id is still ours to signal.
        guard OwnChild.isUnreaped(leader), !OwnChild.hasExited(leader) else { return .exitedOnTerm }
        _ = send(-leader, SIGKILL)
        return .killed
    }
}
