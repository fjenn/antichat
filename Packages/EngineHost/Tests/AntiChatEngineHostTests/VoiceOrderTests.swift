// M3 review P2-1: the voice messages acting on one stream run in arrival order (speak deltas, speakEnd after the last
// delta, pttUp after pttDown), however the executor schedules them; different streams do not wait for each other.
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngineHost

@Suite struct VoiceOrderTests {
    @Test func messagesOfOneStreamRunInArrivalOrder() async {
        let order = VoiceOrder()
        let id = UUID()
        let seen = Mutex<[Int]>([])
        let done = Mutex(0)
        for i in 0..<200 {
            order.enqueue(id) {
                // Uneven work: a later message would overtake an earlier one if they raced.
                if i % 7 == 0 { try? await Task.sleep(for: .milliseconds(2)) }
                seen.withLock { $0.append(i) }
                done.withLock { $0 += 1 }
            }
        }
        let end = ContinuousClock.now + .seconds(20)
        while done.withLock({ $0 }) < 200, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(seen.withLock { $0 } == Array(0..<200))
        while order.queued > 0, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(order.queued == 0, "a drained stream leaves nothing behind")
    }

    @Test func streamsDoNotWaitForEachOther() async {
        let order = VoiceOrder()
        let blocked = UUID(), other = UUID()
        let release = Mutex(false)
        let otherRan = Mutex(false)
        order.enqueue(blocked) {
            while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) }
        }
        order.enqueue(other) { otherRan.withLock { $0 = true } }
        let end = ContinuousClock.now + .seconds(10)
        while !otherRan.withLock({ $0 }), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(otherRan.withLock { $0 })
        release.withLock { $0 = true }
    }
}
