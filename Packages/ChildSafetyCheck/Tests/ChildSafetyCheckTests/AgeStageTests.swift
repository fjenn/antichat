// F7 tail (A-M9-T05-F7): the age stage takes every query of an image in ONE MiVOLO call and every body-only crop in ONE
// age-bin call, prepares their tensors in parallel on the CPU, and runs the age bins (Accelerate) beside the MiVOLO runs
// (ONNX Runtime). These tests pin that nothing else changed: the same stages run for the same images, the verdicts and
// every recorded score equal the pre-change per-query algorithm (re-implemented here as the reference), every error,
// timeout and missing model still fails closed, the overlap and concurrent callers change no result, and the queries
// really arrive batched. Stub detectors and content-free canvases only (D-017): the stubs derive their answers from
// the crop SIZE (never the pixels), so every fixture is a blank canvas.
import CoreGraphics
import Foundation
import Testing
@testable import ChildSafetyCheck

// MARK: - Recording stubs

/// Counts how many callers are inside at once and the peak.
final class PeakCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var top = 0
    var peak: Int { lock.withLock { top } }
    func enter() { lock.withLock { n += 1; top = max(top, n) } }
    func leave() { lock.withLock { n -= 1 } }
}

/// MiVOLO stand-in. Face query ⇒ age = face crop width; body-only query ⇒ age = body crop height / 4. Records each
/// `ages` batch, single calls, and (with `overlap`) how many age/bin calls were in flight at once.
final class RecordingAge: AgeEstimating, @unchecked Sendable {
    enum Mode { case ok, fail, wrongCount, nonFinite, slow(Double), hang(Hang) }
    let mode: Mode
    let overlap: PeakCounter?
    let ownPeak = PeakCounter()
    private let lock = NSLock()
    private var batchList: [Int] = []
    private var singles = 0
    init(_ mode: Mode = .ok, overlap: PeakCounter? = nil) {
        self.mode = mode
        self.overlap = overlap
    }
    var batches: [Int] { lock.withLock { batchList } }
    var singleCalls: Int { lock.withLock { singles } }

    static func answer(_ i: AgeInput) -> Double {
        if let f = i.face { return Double(f.width) }
        return Double(i.body?.height ?? 0) / 4
    }

    func age(face: CGImage?, body: CGImage?) throws -> Double {
        lock.withLock { singles += 1 }
        return Self.answer(AgeInput(face: face, body: body))
    }

    func ages(_ inputs: [AgeInput]) throws -> [Double] {
        lock.withLock { batchList.append(inputs.count) }
        ownPeak.enter(); overlap?.enter()
        defer { ownPeak.leave(); overlap?.leave() }
        switch mode {
        case .ok: break
        case .fail: throw StubError()
        case .wrongCount: return inputs.dropLast().map(Self.answer)
        case .nonFinite: return inputs.map { _ in .nan }
        case .slow(let s): Thread.sleep(forTimeInterval: s)
        case .hang(let h): h.block()
        }
        return inputs.map(Self.answer)
    }
}

/// Age-bin stand-in: P(child + teen) = body crop width / 1000.
final class RecordingBins: AgeBinScoring, @unchecked Sendable {
    enum Mode { case ok, fail, wrongCount, nonFinite, slow(Double), hang(Hang) }
    let mode: Mode
    let overlap: PeakCounter?
    let ownPeak = PeakCounter()
    private let lock = NSLock()
    private var batchList: [Int] = []
    init(_ mode: Mode = .ok, overlap: PeakCounter? = nil) {
        self.mode = mode
        self.overlap = overlap
    }
    var batches: [Int] { lock.withLock { batchList } }

    static func answer(_ image: CGImage) -> Double { Double(image.width) / 1000 }

    func youngProbability(_ image: CGImage) throws -> Double { Self.answer(image) }

    func youngProbabilities(_ images: [CGImage]) throws -> [Double] {
        lock.withLock { batchList.append(images.count) }
        ownPeak.enter(); overlap?.enter()
        defer { ownPeak.leave(); overlap?.leave() }
        switch mode {
        case .ok: break
        case .fail: throw StubError()
        case .wrongCount: return []
        case .nonFinite: return images.map { _ in .nan }
        case .slow(let s): Thread.sleep(forTimeInterval: s)
        case .hang(let h): h.block()
        }
        return images.map(Self.answer)
    }
}

/// People stand-in that counts its calls.
final class CountingPeople: PeopleDetecting, @unchecked Sendable {
    let boxes: PeopleBoxes
    let calls = Counter()
    init(_ boxes: PeopleBoxes) { self.boxes = boxes }
    func detect(_ image: CGImage) throws -> PeopleBoxes {
        _ = calls.next()
        return boxes
    }
}

// MARK: - Fixtures

struct AgeFixture: Sendable, CustomTestStringConvertible {
    let name: String
    let nudity: Double
    let people: PeopleBoxes
    let bins: Bool
    var forceFullPath = false
    var testDescription: String { name }

    var thresholds: Thresholds {
        var t = Thresholds()
        t.tAgeBins = bins ? 0.3 : .infinity
        t.timeout = 30
        return t
    }
}

private func face(_ x: Double, _ y: Double, _ side: Double, conf: Double = 0.9) -> FaceBox {
    FaceBox(rect: CGRect(x: x, y: y, width: side, height: side), confidence: conf)
}

/// Canvas 512². Face boundary 18 + 7 = 25 y (face width), body boundary 18 + 12 = 30 y (height / 4), bins 0.3 (width).
let ageFixtures: [AgeFixture] = [
    AgeFixture(name: "not nude, two faces: no people/age stage", nudity: 0.1,
               people: PeopleBoxes(faces: [face(10, 10, 24), face(100, 10, 40)], bodies: []), bins: true),
    AgeFixture(name: "nude, nobody", nudity: 0.9, people: PeopleBoxes(faces: [], bodies: []), bins: true),
    AgeFixture(name: "nude, one adult face in its body", nudity: 0.9,
               people: PeopleBoxes(faces: [face(20, 10, 40)], bodies: [CGRect(x: 0, y: 0, width: 100, height: 300)]), bins: true),
    AgeFixture(name: "nude, one young face", nudity: 0.9,
               people: PeopleBoxes(faces: [face(20, 10, 24)], bodies: [CGRect(x: 0, y: 0, width: 100, height: 300)]), bins: true),
    AgeFixture(name: "nude, three adult faces + one adult body-only (bins low)", nudity: 0.9,
               people: PeopleBoxes(faces: [face(10, 10, 40), face(110, 10, 50), face(210, 10, 60)],
                                   bodies: [CGRect(x: 0, y: 0, width: 90, height: 300), CGRect(x: 100, y: 0, width: 90, height: 300),
                                            CGRect(x: 200, y: 0, width: 90, height: 300), CGRect(x: 300, y: 0, width: 100, height: 200)]),
               bins: true),
    AgeFixture(name: "nude, three adult faces + one body-only the bins call young", nudity: 0.9,
               people: PeopleBoxes(faces: [face(10, 10, 40), face(110, 10, 50), face(210, 10, 60)],
                                   bodies: [CGRect(x: 0, y: 0, width: 90, height: 300), CGRect(x: 100, y: 0, width: 90, height: 300),
                                            CGRect(x: 200, y: 0, width: 90, height: 300), CGRect(x: 100, y: 200, width: 400, height: 300)]),
               bins: true),
    AgeFixture(name: "nude, one young body-only, bins off", nudity: 0.9,
               people: PeopleBoxes(faces: [], bodies: [CGRect(x: 0, y: 0, width: 50, height: 100)]), bins: false),
    AgeFixture(name: "nude, two adult body-only, bins on", nudity: 0.9,
               people: PeopleBoxes(faces: [], bodies: [CGRect(x: 0, y: 0, width: 60, height: 200), CGRect(x: 200, y: 0, width: 80, height: 240)]),
               bins: true),
    AgeFixture(name: "nude, ten adult faces without bodies", nudity: 0.9,
               people: PeopleBoxes(faces: (0..<10).map { face(Double($0) * 50, 300, Double(30 + $0)) }, bodies: []), bins: true),
    AgeFixture(name: "nude, unusable faces ⇒ their bodies are body-only", nudity: 0.9,
               people: PeopleBoxes(faces: [face(10, 10, 40, conf: 0.3), face(110, 10, 20)],
                                   bodies: [CGRect(x: 0, y: 0, width: 90, height: 200), CGRect(x: 100, y: 0, width: 350, height: 200)]),
               bins: true),
    AgeFixture(name: "forced full path on a non-nude image with a young face", nudity: 0.1,
               people: PeopleBoxes(faces: [face(20, 10, 24)], bodies: []), bins: true, forceFullPath: true),
]

/// What the rule saw, comparable bit for bit.
struct AgeOutcome: Equatable, CustomStringConvertible {
    var verdict: ChildSafetyCheck.Verdict
    var nude: Bool?
    var minor: Bool?
    var faceAges: [UInt64]
    var bodyOnlyAges: [UInt64]
    var bodyOnlyYoung: [UInt64]
    var failed: Bool
    init(_ t: ChildSafetyCheck.Trace) {
        verdict = t.verdict
        nude = t.nude
        minor = t.minor
        faceAges = t.faceAges.map(\.bitPattern)
        bodyOnlyAges = t.bodyOnlyAges.map(\.bitPattern)
        bodyOnlyYoung = t.bodyOnlyYoung.map(\.bitPattern)
        failed = t.failure != nil
    }
    init(verdict: ChildSafetyCheck.Verdict, nude: Bool?, minor: Bool?, faceAges: [Double], bodyOnlyAges: [Double],
         bodyOnlyYoung: [Double]) {
        self.verdict = verdict
        self.nude = nude
        self.minor = minor
        self.faceAges = faceAges.map(\.bitPattern)
        self.bodyOnlyAges = bodyOnlyAges.map(\.bitPattern)
        self.bodyOnlyYoung = bodyOnlyYoung.map(\.bitPattern)
        failed = false
    }
    var description: String { "\(verdict) nude=\(String(describing: nude)) minor=\(String(describing: minor)) faces=\(faceAges.count) bodies=\(bodyOnlyAges.count) young=\(bodyOnlyYoung.count) failed=\(failed)" }
}

/// The pre-change age stage, query by query (ChildSafetyCheck.analyze before A-M9-T05-F7), as the reference.
func referenceOutcome(_ f: AgeFixture, image: CGImage) -> AgeOutcome {
    let t = f.thresholds
    let nude = DecisionRule.isNude(n: f.nudity, n2: nil, t)
    guard nude || f.forceFullPath else {
        return AgeOutcome(verdict: .allow, nude: nude, minor: nil, faceAges: [], bodyOnlyAges: [], bodyOnlyYoung: [])
    }
    var faceAges: [Double] = [], bodyAges: [Double] = [], young: [Double] = []
    for q in DecisionRule.ageQueries(f.people, t) {
        let fc = q.face.flatMap { ImageTensor.crop(image, $0) }
        let bc = q.body.flatMap { ImageTensor.crop(image, $0) }
        let a = RecordingAge.answer(AgeInput(face: fc, body: bc))
        switch q.kind {
        case .face: faceAges.append(a)
        case .bodyOnly:
            bodyAges.append(a)
            if t.tAgeBins.isFinite, let bc { young.append(RecordingBins.answer(bc)) }
        }
    }
    let minor = DecisionRule.isMinor(faceAges: faceAges, bodyOnlyAges: bodyAges, bodyOnlyYoung: young, t)
    return AgeOutcome(verdict: DecisionRule.verdict(nude: nude, minor: minor), nude: nude, minor: minor,
                      faceAges: faceAges, bodyOnlyAges: bodyAges, bodyOnlyYoung: young)
}

/// This suite's own evaluation lane (serial, like the process-wide one): another suite's deliberately hung detector on
/// the shared lane cannot queue these checks into their deadline.
let ageStageLane = DispatchQueue(label: "AgeStageTests.lane", qos: .userInitiated)

func ageCheck(_ f: AgeFixture, age: RecordingAge = RecordingAge(), bins: RecordingBins? = RecordingBins(),
              people: CountingPeople? = nil, timeout: Double? = nil, lane: DispatchQueue = ageStageLane) -> ChildSafetyCheck {
    var t = f.thresholds
    if let timeout { t.timeout = timeout }
    return ChildSafetyCheck(detectors: .init(nudity: StubNudity(mode: .score(f.nudity)), nudity2: nil,
                                             people: people ?? CountingPeople(f.people), age: age, ageBins: bins),
                            thresholds: t, retryTimeout: 0.5, lane: lane)
}

/// A blank 512² canvas (fresh each use: the stubs only read crop sizes).
var canvas512: CGImage { blankImage(512) }

// MARK: - Tests

@Suite struct AgeStageTests {
    /// The stage set and every verdict and score equal the pre-change per-query algorithm on the fixture set.
    @Test(arguments: ageFixtures) func stagesAndVerdictUnchanged(_ f: AgeFixture) async {
        let age = RecordingAge(), bins = RecordingBins(), people = CountingPeople(f.people)
        let trace = await ageCheck(f, age: age, bins: bins, people: people)
            .evaluateDetailed(image: canvas512, forceFullPath: f.forceFullPath)
        #expect(AgeOutcome(trace) == referenceOutcome(f, image: canvas512))
        // Stage set: people (and so the age stage) only when nude or forced; MiVOLO iff there is a query; age bins iff
        // a body-only query exists and the bins are enabled. Nothing runs a detector per query any more.
        let t = f.thresholds
        let full = DecisionRule.isNude(n: f.nudity, n2: nil, t) || f.forceFullPath
        let queries = full ? DecisionRule.ageQueries(f.people, t) : []
        let bodyOnly = queries.filter { $0.kind == .bodyOnly }.count
        #expect(people.calls.value == (full ? 1 : 0))
        #expect(age.batches == (queries.isEmpty ? [] : [queries.count]))
        #expect(bins.batches == (bodyOnly > 0 && t.tAgeBins.isFinite ? [bodyOnly] : []))
        #expect(age.singleCalls == 0)
    }

    /// All faces (and bodies) of an image reach MiVOLO in one call, all body-only crops reach the bins in one call.
    @Test func facesAreBatchedIntoOneCall() async {
        let faces = (0..<6).map { face(Double($0) * 80 + 10, 10, 30 + Double($0)) }
        let bodies = (0..<6).map { CGRect(x: Double($0) * 80, y: 0, width: 70, height: 300) }
            + [CGRect(x: 0, y: 320, width: 120, height: 180), CGRect(x: 200, y: 320, width: 150, height: 180)]
        let f = AgeFixture(name: "6 faces in bodies + 2 body-only", nudity: 0.9, people: PeopleBoxes(faces: faces, bodies: bodies), bins: true)
        let age = RecordingAge(), bins = RecordingBins()
        let trace = await ageCheck(f, age: age, bins: bins).evaluateDetailed(image: canvas512)
        #expect(age.batches == [8] && age.singleCalls == 0, "one MiVOLO call carrying all 8 queries")
        #expect(bins.batches == [2], "one age-bin call carrying both body-only crops")
        #expect(trace.faceAges.count == 6 && trace.bodyOnlyAges.count == 2 && trace.bodyOnlyYoung.count == 2)
        #expect(AgeOutcome(trace) == referenceOutcome(f, image: canvas512))
    }

    /// The default `ages` / `youngProbabilities` (any other conformer) answer exactly what the single calls answer.
    @Test func defaultBatchCallsEqualSingleCalls() throws {
        let crops = [solid(30, 40, r: 0, g: 0, b: 0), solid(64, 20, r: 1, g: 1, b: 1)]
        let age = StubAge(faceAge: 31, bodyAge: 44)
        let inputs = [AgeInput(face: crops[0], body: crops[1]), AgeInput(face: nil, body: crops[1])]
        #expect(try age.ages(inputs) == [31, 44])
        #expect(try StubAgeBins(young: 0.25).youngProbabilities(crops) == [0.25, 0.25])
        #expect(try age.ages([]) == [])
    }

    // MARK: fail closed

    static let failFixture = ageFixtures[5]  // nude, three faces + one body-only: both age calls run

    @Test(arguments: 0..<3)
    func mivoloErrorWhileNudeBlocks(_ i: Int) async {
        let mode = [RecordingAge.Mode.fail, .wrongCount, .nonFinite][i]
        let tr = await ageCheck(Self.failFixture, age: RecordingAge(mode)).evaluateDetailed(image: canvas512)
        #expect(tr.verdict == .block && tr.failure != nil)
    }

    @Test(arguments: 0..<3)
    func ageBinErrorWhileNudeBlocks(_ i: Int) async {
        let mode = [RecordingBins.Mode.fail, .wrongCount, .nonFinite][i]
        // An adult-only image (fixture 4: bins say 0.1): an error must still block, never fall back to "adult".
        let tr = await ageCheck(ageFixtures[4], bins: RecordingBins(mode)).evaluateDetailed(image: canvas512)
        #expect(tr.verdict == .block && tr.failure != nil)
    }

    @Test func ageStageErrorWhileNotNudeAllows() async {
        // Unchanged rule: not nude ⇒ allow; on the forced full path an age error does not turn that into a block.
        var f = ageFixtures[4]
        f = AgeFixture(name: f.name, nudity: 0.1, people: f.people, bins: true, forceFullPath: true)
        let tr = await ageCheck(f, age: RecordingAge(.fail)).evaluateDetailed(image: canvas512, forceFullPath: true)
        #expect(tr.verdict == .allow && tr.failure != nil)
    }

    @Test func ageBinsEnabledButMissingBlocks() async {
        let tr = await ageCheck(ageFixtures[4], bins: nil).evaluateDetailed(image: canvas512)
        #expect(tr.verdict == .block && tr.failure == .modelMissing("age bins"))
    }

    @Test func aFailedCropBlocksBeforeAnyModelRuns() async {
        // A face box entirely outside the canvas yields no crop: preprocessing error ⇒ block, nothing estimated.
        let f = AgeFixture(name: "face off canvas", nudity: 0.9,
                           people: PeopleBoxes(faces: [face(600, 600, 40)], bodies: []), bins: true)
        let age = RecordingAge()
        let tr = await ageCheck(f, age: age).evaluateDetailed(image: canvas512)
        #expect(tr.verdict == .block && tr.failure == .preprocessing)
        #expect(age.batches.isEmpty)
    }

    /// A hung MiVOLO or a hung age-bin call trips the deadline ⇒ block (and the other half does not outlive it).
    @Test(arguments: [true, false]) func hungAgeStageTimesOutAndBlocks(_ hangMivolo: Bool) async {
        let hang = Hang()
        let age = hangMivolo ? RecordingAge(.hang(hang)) : RecordingAge()
        let bins = hangMivolo ? RecordingBins() : RecordingBins(.hang(hang))
        let lane = DispatchQueue(label: "AgeStageTests.hang", qos: .userInitiated)
        let tr = await ageCheck(Self.failFixture, age: age, bins: bins, timeout: 0.2, lane: lane).evaluateDetailed(image: canvas512)
        #expect(tr.verdict == .block && tr.failure == .timeout)
        hang.release()
        // The timed-out evaluation still held its lane until both halves ended: the next check on the lane runs after it.
        let next = await ageCheck(ageFixtures[2], lane: lane).evaluateDetailed(image: canvas512)
        #expect(next.verdict == .allow && hang.finished)
    }

    @Test func missingAgeModelsThrowAtLoad() {
        let nowhere = FileManager.default.temporaryDirectory.appending(path: "csc-none-\(UUID().uuidString)")
        #expect(throws: DetectorError.modelMissing(URL(fileURLWithPath: MiVOLOAge.relativePath).lastPathComponent)) {
            _ = try MiVOLOAge(modelDirectory: nowhere, provider: .cpu)
        }
        #expect(throws: DetectorError.modelMissing(URL(fileURLWithPath: SigLIPAgeBins.relativePath).lastPathComponent)) {
            _ = try SigLIPAgeBins(modelDirectory: nowhere)
        }
    }

    // MARK: concurrency

    /// The age bins really run beside MiVOLO inside one evaluation, and that changes no result.
    @Test func binsOverlapMivoloWithoutChangingResults() async {
        let inFlight = PeakCounter()
        let age = RecordingAge(.slow(0.05), overlap: inFlight), bins = RecordingBins(.slow(0.05), overlap: inFlight)
        let f = ageFixtures[5]
        let trace = await ageCheck(f, age: age, bins: bins).evaluateDetailed(image: canvas512)
        #expect(inFlight.peak == 2, "MiVOLO and the age bins overlapped")
        #expect(AgeOutcome(trace) == referenceOutcome(f, image: canvas512))
        #expect(trace.verdict == .block)
    }

    /// Many concurrent callers over the whole fixture set get exactly the serial outcomes; evaluations never overlap
    /// (each engine's calls stay one at a time across evaluations).
    @Test func concurrentEvaluationsMatchSerialOutcomes() async {
        let age = RecordingAge(.slow(0.002)), bins = RecordingBins(.slow(0.002))
        let checks = ageFixtures.map { ageCheck($0, age: age, bins: bins) }
        var serial: [AgeOutcome] = []
        for (f, c) in zip(ageFixtures, checks) {
            serial.append(AgeOutcome(await c.evaluateDetailed(image: canvas512, forceFullPath: f.forceFullPath)))
        }
        #expect(serial == ageFixtures.map { referenceOutcome($0, image: canvas512) })
        let concurrent = await withTaskGroup(of: (Int, AgeOutcome).self) { g in
            for k in 0..<(ageFixtures.count * 4) {
                let i = k % ageFixtures.count
                g.addTask { (i, AgeOutcome(await checks[i].evaluateDetailed(image: canvas512, forceFullPath: ageFixtures[i].forceFullPath))) }
            }
            var out: [(Int, AgeOutcome)] = []
            for await r in g { out.append(r) }
            return out
        }
        #expect(concurrent.count == ageFixtures.count * 4)
        for (i, o) in concurrent { #expect(o == serial[i], "fixture \(ageFixtures[i].name)") }
        #expect(age.ownPeak.peak == 1, "no two MiVOLO calls overlapped")
        #expect(bins.ownPeak.peak == 1, "no two age-bin calls overlapped")
    }
}

// MARK: - Preprocessing (bit-identical, parallel)

@Suite struct AgePreprocessingTests {
    @Test(arguments: 0..<2)
    func blackFrameFastPathIsBitIdentical(_ m: Int) throws {
        let mode = [ResizeMode.squash, .letterbox][m]
        for (mean, std) in [(MiVOLOAge.mean, MiVOLOAge.std), ([Float](repeating: 0.5, count: 3), [Float](repeating: 0.5, count: 3))] {
            let fast = try ImageTensor.chw(nil, side: 32, mode: mode, mean: mean, std: std)
            let drawn = try ImageTensor.chw(solid(32, 32, r: 0, g: 0, b: 0), side: 32, mode: mode, mean: mean, std: std)
            #expect(fast.map(\.bitPattern) == drawn.map(\.bitPattern))
        }
    }

    @Test func normalizeMatchesTheScalarFormulaBitForBit() {
        var rng = SystemRandomNumberGenerator()
        let plane = 17 * 13
        let px = (0..<(plane * 4)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let mean = MiVOLOAge.mean, std = MiVOLOAge.std
        var ref = [Float](repeating: 0, count: 3 * plane)
        for c in 0..<3 { for i in 0..<plane { ref[c * plane + i] = (Float(px[i * 4 + c]) / 255 - mean[c]) / std[c] } }
        #expect(ImageTensor.normalize(rgbx: px, plane: plane, mean: mean, std: std).map(\.bitPattern) == ref.map(\.bitPattern))
    }

    @Test func parallelTensorsEqualSerialTensors() throws {
        // Content-free crops of different sizes and colours (a gradient-free palette; D-017).
        let crops = (0..<9).map { k in solid(20 + k * 13, 90 - k * 5, r: CGFloat(k) / 9, g: 0.5, b: 1 - CGFloat(k) / 9) }
        let inputs = crops.indices.map { AgeInput(face: $0 % 3 == 0 ? nil : crops[$0], body: crops[($0 + 1) % crops.count]) }
        let serial = try inputs.map { try MiVOLOAge.tensor($0).map(\.bitPattern) }
        let parallel = try ImageTensor.concurrentMap(inputs) { try MiVOLOAge.tensor($0) }.map { $0.map(\.bitPattern) }
        #expect(parallel == serial)
        let binsSerial = try crops.map { try SigLIPAgeBins.tensor($0).map(\.bitPattern) }
        let binsParallel = try ImageTensor.concurrentMap(crops.map(SendableImage.init)) { try SigLIPAgeBins.tensor($0.image) }
        #expect(binsParallel.map { $0.map(\.bitPattern) } == binsSerial)
    }

    @Test func concurrentMapKeepsOrderAndRethrowsTheFirstError() {
        #expect((try? ImageTensor.concurrentMap(Array(0..<100)) { $0 * 2 }) == (0..<100).map { $0 * 2 })
        #expect(throws: DetectorError.preprocessing) {
            _ = try ImageTensor.concurrentMap(Array(0..<50)) { i -> Int in
                if i == 7 { throw DetectorError.preprocessing }
                if i == 30 { throw DetectorError.timeout }
                return i
            }
        }
    }
}

/// Real detectors (opt-in, CSC_REAL_DETECTORS=1): the one-call paths give exactly the single-call answers.
@Suite(.enabled(if: RealDetectors.directory != nil, "set CSC_REAL_DETECTORS=1 with the dev detector models installed"))
struct RealAgeStageTests {
    @Test(arguments: [ExecutionProvider.cpu, .coreml]) func batchedCallsEqualSingleCalls(_ ep: ExecutionProvider) throws {
        let dir = try #require(RealDetectors.directory)
        let crops = (0..<4).map { k in solid(60 + k * 40, 200 - k * 30, r: 0.2 * CGFloat(k), g: 0.4, b: 0.6) }
        let inputs = [AgeInput(face: crops[0], body: crops[1]), AgeInput(face: nil, body: crops[2]),
                      AgeInput(face: crops[3], body: nil), AgeInput(face: crops[1], body: crops[3])]
        let age = try MiVOLOAge(modelDirectory: dir, provider: ep)
        let single = try inputs.map { try age.age(face: $0.face, body: $0.body) }
        #expect(try age.ages(inputs).map(\.bitPattern) == single.map(\.bitPattern))
        if FileManager.default.fileExists(atPath: dir.appending(path: SigLIPAgeBins.relativePath).path) {
            let bins = try SigLIPAgeBins(modelDirectory: dir)
            let one = try crops.map { try bins.youngProbability($0) }
            #expect(try bins.youngProbabilities(crops).map(\.bitPattern) == one.map(\.bitPattern))
        }
    }
}
