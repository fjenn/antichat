// Verdicts must not depend on concurrency (M4 lead, after the calibration-set finding: concurrent evaluations on one
// checker changed nudity scores run to run and once a verdict). Every evaluation runs on one process-wide lane and
// every model run holds its engine's InferenceLock (onnx or accelerate), so concurrent callers — video frames and
// previews included — get exactly the results of serial runs. (A-M9-T05-F7: inside one evaluation the age bins may run
// beside MiVOLO, two different engines; AgeStageTests pins that this changes no result.)
import CoreGraphics
import Foundation
import Testing
@testable import ChildSafetyCheck

/// A scorer whose output would change if two calls overlapped (the measured CoreML behaviour, made deterministic):
/// it records the peak number of calls in flight and answers `overlapped` while another call is running.
final class RacyNudity: NudityScoring, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var peak = 0
    let alone: Double, overlapped: Double
    init(alone: Double, overlapped: Double) { self.alone = alone; self.overlapped = overlapped }
    func nudityScore(_ image: CGImage) throws -> Double {
        let n = lock.withLock { inFlight += 1; peak = max(peak, inFlight); return inFlight }
        Thread.sleep(forTimeInterval: 0.004)  // a window for another call to land in
        let seen = lock.withLock { () -> Int in let m = max(n, inFlight); inFlight -= 1; return m }
        return seen > 1 ? overlapped : alone
    }
}

/// Age estimator with the same property, per call (the full path: nude ⇒ people ⇒ age).
final class RacyAge: AgeEstimating, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var peak = 0
    func age(face: CGImage?, body: CGImage?) throws -> Double {
        let n = lock.withLock { inFlight += 1; peak = max(peak, inFlight); return inFlight }
        Thread.sleep(forTimeInterval: 0.002)
        let seen = lock.withLock { () -> Int in let m = max(n, inFlight); inFlight -= 1; return m }
        return seen > 1 ? 30 : 12  // overlapping runs would read as an adult
    }
}

@Suite struct SerialInferenceTests {
    func checker(_ nudity: RacyNudity, _ age: RacyAge) -> ChildSafetyCheck {
        // Two faces in two bodies: two age queries per image (the old per-image lanes ran them concurrently).
        let faces = [FaceBox(rect: CGRect(x: 4, y: 4, width: 26, height: 26), confidence: 0.9),
                     FaceBox(rect: CGRect(x: 34, y: 4, width: 26, height: 26), confidence: 0.9)]
        let bodies = [CGRect(x: 0, y: 0, width: 32, height: 64), CGRect(x: 32, y: 0, width: 32, height: 64)]
        var t = Thresholds()
        t.timeout = 30
        return ChildSafetyCheck(detectors: .init(nudity: nudity, nudity2: nil,
                                                 people: StubPeople(boxes: PeopleBoxes(faces: faces, bodies: bodies)),
                                                 age: age, ageBins: nil), thresholds: t)
    }

    @Test func concurrentCallsMatchSerialRunsBitForBit() async {
        let nudity = RacyNudity(alone: 0.9, overlapped: 0.1)  // overlap would read as "not nude" ⇒ allow
        let age = RacyAge()
        let check = checker(nudity, age)
        let image = blankImage()
        var serial: [ChildSafetyCheck.Trace] = []
        for _ in 0..<4 { serial.append(await check.evaluateDetailed(image: image)) }
        #expect(serial.allSatisfy { $0.verdict == .block && $0.nudity == 0.9 && $0.faceAges == [12, 12] })
        let concurrent = await withTaskGroup(of: ChildSafetyCheck.Trace.self) { g in
            for _ in 0..<24 { g.addTask { await check.evaluateDetailed(image: image) } }
            var out: [ChildSafetyCheck.Trace] = []
            for await t in g { out.append(t) }
            return out
        }
        #expect(concurrent.count == 24)
        for t in concurrent {
            #expect(t.verdict == serial[0].verdict)
            #expect(t.nudity?.bitPattern == serial[0].nudity?.bitPattern)
            #expect(t.faceAges.map(\.bitPattern) == serial[0].faceAges.map(\.bitPattern))
        }
        #expect(nudity.peak == 1, "no two nudity runs overlapped")
        #expect(age.peak == 1, "no two age runs overlapped (also within one image)")
    }

    @Test func separateCheckersShareTheLane() async {
        let n1 = RacyNudity(alone: 0.9, overlapped: 0.1), n2 = RacyNudity(alone: 0.9, overlapped: 0.1)
        let shared = SharedPeak()
        let a = checker(n1, RacyAge()), b = checker(n2, RacyAge())
        let image = blankImage()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<16 {
                g.addTask {
                    shared.enter()
                    let v = await (i % 2 == 0 ? a : b).evaluate(image: image)
                    shared.leave()
                    #expect(v == .block)
                }
            }
        }
        #expect(n1.peak == 1 && n2.peak == 1)
    }

    @Test func videoFramesAndPreviewsAreSerialToo() async {
        let nudity = RacyNudity(alone: 0.0, overlapped: 0.9)  // overlap would read as nude
        let check = checker(nudity, RacyAge())
        let frames = (0..<12).map { VideoFrame(index: $0, image: blankImage(), isPreview: $0 % 3 == 0) }
        async let video = check.evaluateVideo(frames: AsyncThrowingStream { c in frames.forEach { c.yield($0) }; c.finish() },
                                              frameCount: 12, fps: 4)
        async let still = check.evaluate(image: blankImage())
        let (v, s) = await (video, still)
        #expect(v == .allow && s == .allow)
        #expect(nudity.peak == 1)
    }

    /// Each engine lock admits one model run at a time, process-wide (0 = onnx, 1 = accelerate). The peak is counted
    /// inside the bodies, so runs of other suites cannot disturb it.
    @Test(arguments: [0, 1]) func modelRunsHoldTheProcessWideEngineLock(_ which: Int) async {
        let engine = which == 0 ? InferenceLock.onnx : InferenceLock.accelerate
        let inside = PeakCounter()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 {
                g.addTask { engine.run { inside.enter(); Thread.sleep(forTimeInterval: 0.002); inside.leave() } }
            }
        }
        #expect(inside.peak == 1)
    }

    /// `InferenceLock.run` (every OrtModel run) is the onnx lock; the age-bin forward holds the accelerate lock, a
    /// different one: an age-bin forward may run while an ONNX run is in progress (within one evaluation, `ageStage`).
    @Test func theTwoEnginesAreSeparateLocks() {
        #expect(InferenceLock.onnx !== InferenceLock.accelerate)
        let onnxInside = DispatchSemaphore(value: 0), accelerateRan = DispatchSemaphore(value: 0)
        let overlapped = PeakCounter()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            InferenceLock.run {
                onnxInside.signal()
                if accelerateRan.wait(timeout: .now() + 5) == .success { overlapped.enter() }
            }
            done.signal()
        }
        onnxInside.wait()
        InferenceLock.accelerate.run { accelerateRan.signal() }
        done.wait()
        #expect(overlapped.peak == 1, "the accelerate lock was free while an onnx run held its lock")
    }
}

final class SharedPeak: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func enter() { lock.withLock { n += 1 } }
    func leave() { lock.withLock { n -= 1 } }
}
