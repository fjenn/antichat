// Video sampling (D-014, NFR-F9 unit part): ≥ 2 fps + first + last; every preview checked; fail closed.
import CoreGraphics
import Foundation
import os
import Testing
@testable import ChildSafetyCheck

@Suite struct VideoFrameSamplerTests {
    @Test(arguments: [8.0, 16.0, 24.0, 30.0], [1, 2, 81, 241])
    func indicesCoverClip(fps: Double, frameCount: Int) {
        let idx = ChildSafetyCheck.sampleIndices(frameCount: frameCount, fps: fps)
        #expect(idx.first == 0)
        #expect(idx.last == frameCount - 1)
        #expect(idx == Array(Set(idx)).sorted())                       // sorted, no duplicates
        #expect(idx.allSatisfy { (0..<frameCount).contains($0) })
        let gaps = zip(idx.dropFirst(), idx).map { $0 - $1 }
        #expect(gaps.allSatisfy { Double($0) <= fps / 2 })            // ≥ 2 checked frames per second
    }

    @Test func stepIsFloorOfHalfFps() {
        #expect(ChildSafetyCheck.sampleIndices(frameCount: 10, fps: 8) == [0, 4, 8, 9])
        #expect(ChildSafetyCheck.sampleIndices(frameCount: 17, fps: 16) == [0, 8, 16])
        #expect(ChildSafetyCheck.sampleIndices(frameCount: 5, fps: 3) == [0, 1, 2, 3, 4])   // floor(1.5) = 1
        #expect(ChildSafetyCheck.sampleIndices(frameCount: 3, fps: 1) == [0, 1, 2])         // < 2 fps ⇒ every frame
        #expect(ChildSafetyCheck.sampleIndices(frameCount: 3, fps: .nan) == [0, 1, 2])
        #expect(ChildSafetyCheck.sampleIndices(frameCount: 0, fps: 16) == [])
        #expect(ChildSafetyCheck.sampleIndices(frameCount: 1, fps: 16) == [0])
    }

    // MARK: evaluateVideo(frames:frameCount:fps:) — stub detectors only; a 65-px-wide blank frame is the
    // stub's "flagged" frame (the stubs never look at pixels, D-017).

    final class Counting: NudityScoring, @unchecked Sendable {
        let n = OSAllocatedUnfairLock(initialState: 0)
        func nudityScore(_ image: CGImage) throws -> Double {
            n.withLock { $0 += 1 }
            return image.width == 65 ? 0.95 : 0.0
        }
        var count: Int { n.withLock { $0 } }
    }

    func check(_ counter: Counting) -> ChildSafetyCheck {
        ChildSafetyCheck(detectors: .init(nudity: counter, nudity2: nil,
                                          people: StubPeople(boxes: PeopleBoxes(faces: [oneFace], bodies: [oneBody])),
                                          age: StubAge(faceAge: 10)),
                         thresholds: Thresholds())
    }

    func stream(_ frames: [VideoFrame], fail: Bool = false) -> AsyncThrowingStream<VideoFrame, Error> {
        AsyncThrowingStream { c in
            frames.forEach { c.yield($0) }
            if fail { c.finish(throwing: StubError()) } else { c.finish() }
        }
    }

    func frames(_ count: Int, flagged: Int? = nil, previews: Set<Int> = []) -> [VideoFrame] {
        (0..<count).map { VideoFrame(index: $0, image: blankImage($0 == flagged ? 65 : 64), isPreview: previews.contains($0)) }
    }

    @Test func checksOnlySampledFramesThenAllows() async {
        let c = Counting()
        let v = await check(c).evaluateVideo(frames: stream(frames(81)), frameCount: 81, fps: 16)
        #expect(v == .allow)
        #expect(c.count == ChildSafetyCheck.sampleIndices(frameCount: 81, fps: 16).count)
    }

    @Test func unsampledPreviewIsChecked() async {
        let c = Counting()
        // Frame 3 is not a sampled index at 16 fps (step 8), but it is a preview ⇒ checked ⇒ blocks.
        let v = await check(c).evaluateVideo(frames: stream(frames(81, flagged: 3, previews: [3])), frameCount: 81, fps: 16)
        #expect(v == .block)
        // The same flagged frame, not a preview and not sampled ⇒ never checked.
        let c2 = Counting()
        #expect(await check(c2).evaluateVideo(frames: stream(frames(81, flagged: 3)), frameCount: 81, fps: 16) == .allow)
    }

    @Test func blocksOnFirstBlockedFrameAndStops() async {
        let c = Counting()
        let v = await check(c).evaluateVideo(frames: stream(frames(81, flagged: 16)), frameCount: 81, fps: 16)
        #expect(v == .block)
        #expect(c.count == 3)  // indices 0, 8, 16, then stop
    }

    @Test func lastFrameIsAlwaysChecked() async {
        let c = Counting()
        #expect(await check(c).evaluateVideo(frames: stream(frames(82, flagged: 81)), frameCount: 82, fps: 16) == .block)
    }

    @Test func failClosedOnShortStreamErrorAndEmpty() async {
        #expect(await check(Counting()).evaluateVideo(frames: stream(frames(40)), frameCount: 81, fps: 16) == .block)
        #expect(await check(Counting()).evaluateVideo(frames: stream(frames(81), fail: true), frameCount: 81, fps: 16) == .block)
        #expect(await check(Counting()).evaluateVideo(frames: stream([]), frameCount: 0, fps: 16) == .block)
    }
}
