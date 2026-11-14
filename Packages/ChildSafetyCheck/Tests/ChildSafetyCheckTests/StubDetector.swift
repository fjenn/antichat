// Stub detectors (test-strategy §2: ChildSafetyCheck unit tests use StubDetector only).
// D-017: the nudity × minor conjunction is tested with mocked scores only. No test touches an image
// with content: every CGImage here is a blank 64×64 canvas that the stubs never inspect.
import CoreGraphics
import Foundation
@testable import ChildSafetyCheck

struct StubError: Error {}

/// A detector call that blocks until the test releases it: trips any deadline however loaded the host is (a fixed
/// sleep can finish before a starved deadline fires). `finished` stays false while the caller has not waited for it.
final class Hang: @unchecked Sendable {
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var done = false
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func block() { gate.wait(); lock.lock(); done = true; lock.unlock() }
    func release() { gate.signal() }
}

/// Counts detector calls (a skipped queued check never calls it).
final class Ran: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func hit() { lock.lock(); n += 1; lock.unlock() }
}

/// Returns a fixed score, throws, sleeps, or blocks until released (to trip the deadline).
struct StubNudity: NudityScoring {
    enum Mode: Sendable { case score(Double), fail, slow(Double, seconds: Double), hang(Double, Hang), counting(Double, Ran) }
    var mode: Mode
    func nudityScore(_ image: CGImage) throws -> Double {
        switch mode {
        case .score(let s): return s
        case .fail: throw StubError()
        case .slow(let s, let seconds):
            Thread.sleep(forTimeInterval: seconds)
            return s
        case .hang(let s, let h):
            h.block()
            return s
        case .counting(let s, let r):
            r.hit()
            return s
        }
    }
}

struct StubPeople: PeopleDetecting {
    var boxes: PeopleBoxes = PeopleBoxes(faces: [], bodies: [])
    var fail = false
    func detect(_ image: CGImage) throws -> PeopleBoxes {
        if fail { throw StubError() }
        return boxes
    }
}

/// Face queries return `faceAge`; body-only queries (face crop nil) return `bodyAge`.
struct StubAge: AgeEstimating {
    var faceAge: Double = 40
    var bodyAge: Double = 40
    var fail = false
    var delay: Double = 0
    func age(face: CGImage?, body: CGImage?) throws -> Double {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if fail { throw StubError() }
        return face == nil ? bodyAge : faceAge
    }
}

/// Body-only age-bin signal: returns a fixed P(child + teen), or throws.
struct StubAgeBins: AgeBinScoring {
    var young: Double = 0
    var fail = false
    func youngProbability(_ image: CGImage) throws -> Double {
        if fail { throw StubError() }
        return young
    }
}

func blankImage(_ side: Int = 64) -> CGImage {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}

/// One usable face (40×? px, conf 0.9) inside one body, on a 64×64 canvas scaled up to fit ≥ 24 px.
let oneFace = FaceBox(rect: CGRect(x: 20, y: 4, width: 26, height: 26), confidence: 0.9)
let oneBody = CGRect(x: 10, y: 0, width: 46, height: 64)

func makeCheck(nudity: StubNudity.Mode = .score(0), nudity2: StubNudity.Mode? = nil,
               people: StubPeople = StubPeople(boxes: PeopleBoxes(faces: [oneFace], bodies: [oneBody])),
               age: StubAge = StubAge(), ageBins: StubAgeBins? = nil,
               thresholds: Thresholds = Thresholds(), queueWait: Double = ChildSafetyCheck.defaultQueueWait,
               retryTimeout: Double = 0.5) -> ChildSafetyCheck {
    ChildSafetyCheck(detectors: .init(nudity: StubNudity(mode: nudity), nudity2: nudity2.map { StubNudity(mode: $0) },
                                      people: people, age: age, ageBins: ageBins),
                     thresholds: thresholds, queueWait: queueWait, retryTimeout: retryTimeout)
}
