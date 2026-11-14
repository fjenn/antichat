// M4 review P2-1 (helper side): MediaJobRunner never lets two jobs into the runner together — the turn passes straight
// to the next waiter, so a newcomer cannot barge in between the resume and the waiter waking up — and a job cancelled
// while it waited ends `jobCancelled` at once, without running its engine (no step-aside, no sd-server start).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct MediaJobRunnerHandOffTests {
    @Test func neverTwoJobsInTheRunner() async {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let inside = Mutex(0)
        let maxInside = Mutex(0)
        await withTaskGroup(of: MediaJobEvent.self) { group in
            for i in 0..<8 {
                group.addTask {
                    await runner.run(job: "j\(i)", safety: nil, previewDir: nil, outputPath: "/nonexistent/\(i).png", emit: { _ in }) { _ in
                        let n = inside.withLock { $0 += 1; return $0 }
                        maxInside.withLock { $0 = max($0, n) }
                        await Task.yield()
                        inside.withLock { $0 -= 1 }
                        return .cancelled
                    }
                }
            }
            for await _ in group {}
        }
        #expect(maxInside.withLock { $0 } == 1)
    }

    @Test func jobCancelledWhileWaitingNeverRunsItsEngine() async {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let firstIn = Mutex(false)
        let releaseFirst = Mutex(false)
        let secondCancelled = Mutex(false)
        let secondRan = Mutex(false)
        let events = Mutex<[MediaJobEvent]>([])
        let first = Task {
            await runner.run(job: "a", safety: nil, previewDir: nil, outputPath: "/nonexistent/a.png", emit: { _ in }) { _ in
                firstIn.withLock { $0 = true }
                while !releaseFirst.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
                return .cancelled
            }
        }
        while !firstIn.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        let second = Task {
            await runner.run(job: "b", safety: nil, previewDir: nil, outputPath: "/nonexistent/b.png",
                             isCancelled: { secondCancelled.withLock { $0 } }, emit: { e in events.withLock { $0.append(e) } }) { _ in
                secondRan.withLock { $0 = true }
                return .completed
            }
        }
        secondCancelled.withLock { $0 = true }  // ■ while b waits behind a
        releaseFirst.withLock { $0 = true }
        _ = await first.value
        let terminal = await second.value
        #expect(terminal == .jobCancelled(job: "b"))
        #expect(!secondRan.withLock { $0 }, "the engine of a job cancelled while waiting never runs")
        #expect(events.withLock { $0 } == [.jobCancelled(job: "b")])
    }
}
