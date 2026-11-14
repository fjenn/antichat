// Fail-closed behaviour (M0.T08 step 3/4, M4.T01 step 6): missing/damaged models ⇒ init throws;
// runtime error or timeout while nudity is true or unknown ⇒ .block.
import CoreGraphics
import Foundation
import Testing
@testable import ChildSafetyCheck

@Suite struct FailClosedTests {
    @Test func missingModelsThrow() throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "csc-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: (any Error).self) { _ = try ChildSafetyCheck(modelDirectory: empty) }
    }

    @Test func corruptModelThrows() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "csc-corrupt-\(UUID().uuidString)")
        let path = dir.appending(path: FreepikNudity.relativePath)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not an onnx file".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: DetectorError.self) { _ = try ChildSafetyCheck(modelDirectory: dir, provider: .cpu) }
    }

    @Test func nudityErrorBlocks() async {
        let tr = await makeCheck(nudity: .fail, age: StubAge(faceAge: 40)).evaluateDetailed(image: blankImage())
        #expect(tr.verdict == .block)
        #expect(tr.nude == nil && tr.failure != nil)
    }

    @Test func secondNudityErrorBlocks() async {
        #expect(await makeCheck(nudity: .score(0.0), nudity2: .fail).evaluate(image: blankImage()) == .block)
    }

    @Test func nonFiniteNudityBlocks() async {
        #expect(await makeCheck(nudity: .score(.nan)).evaluate(image: blankImage()) == .block)
        #expect(await makeCheck(nudity: .score(0.0), nudity2: .score(.nan)).evaluate(image: blankImage()) == .block)
    }

    @Test func peopleErrorWhileNudeBlocks() async {
        #expect(await makeCheck(nudity: .score(0.9), people: StubPeople(fail: true)).evaluate(image: blankImage()) == .block)
    }

    @Test func ageErrorWhileNudeBlocks() async {
        #expect(await makeCheck(nudity: .score(0.9), age: StubAge(fail: true)).evaluate(image: blankImage()) == .block)
    }

    @Test func ageBinsErrorOrAbsenceWhileNudeBlocks() async {
        var t = Thresholds()
        t.tAgeBins = 0.4
        let bodyOnly = StubPeople(boxes: PeopleBoxes(faces: [], bodies: [oneBody]))
        let adult = StubAge(faceAge: 40, bodyAge: 40)
        #expect(await makeCheck(nudity: .score(0.9), people: bodyOnly, age: adult, ageBins: StubAgeBins(fail: true),
                                thresholds: t).evaluate(image: blankImage()) == .block)
        // Enabled by the thresholds but not loaded ⇒ broken install ⇒ block while nude.
        #expect(await makeCheck(nudity: .score(0.9), people: bodyOnly, age: adult, thresholds: t)
            .evaluate(image: blankImage()) == .block)
        #expect(await makeCheck(nudity: .score(0.1), people: bodyOnly, age: adult, ageBins: StubAgeBins(fail: true),
                                thresholds: t).evaluate(image: blankImage()) == .allow)
    }

    @Test func ageErrorWhileNotNudeAllows() async {
        let tr = await makeCheck(nudity: .score(0.1), age: StubAge(fail: true)).evaluateDetailed(image: blankImage(), forceFullPath: true)
        #expect(tr.verdict == .allow)
    }

    @Test func nudityTimeoutBlocks() async {
        var t = Thresholds()
        t.timeout = 0.2
        // Deterministic under load: the detector never answers until released, so the verdict can only come from the
        // deadline, and it came back while the detector was still running (the check did not wait for it).
        let hang = Hang()
        defer { hang.release() }
        let tr = await makeCheck(nudity: .hang(0.0, hang), thresholds: t).evaluateDetailed(image: blankImage())
        #expect(tr.verdict == .block)
        #expect(tr.failure == .timeout)
        #expect(!hang.finished, "the check waited for the detector")
    }

    /// M4 review P1-1: a hung detector holds the lane; a second check still returns `.block` within timeout +
    /// maxQueueWait of being enqueued (it never runs: its caller gave up), and the lane serves checks again once the
    /// hung call returns.
    @Test func hungLaneDoesNotStallLaterChecks() async {
        var t = Thresholds()
        t.timeout = 0.2
        let hang = Hang()
        let first = makeCheck(nudity: .hang(0.0, hang), thresholds: t)
        let firstTask = Task { await first.evaluateDetailed(image: blankImage()) }
        try? await Task.sleep(for: .milliseconds(50))
        let ran = Ran()
        let second = makeCheck(nudity: .counting(0.0, ran), thresholds: t, queueWait: 0.3)
        let t0 = ContinuousClock.now
        let tr = await second.evaluateDetailed(image: blankImage())
        let waited = ContinuousClock.now - t0
        #expect(tr.verdict == .block && tr.failure == .timeout)
        #expect(waited < .seconds(t.timeout + 0.3 + 2), "\(waited)")
        #expect(ran.count == 0, "skipped: its caller had given up")
        hang.release()
        _ = await firstTask.value
        let third = await makeCheck(nudity: .counting(0.1, ran), thresholds: t).evaluateDetailed(image: blankImage())
        #expect(third.verdict == .allow && ran.count == 1, "the lane recovered")
    }

    @Test func ageTimeoutWhileNudeBlocks() async {
        var t = Thresholds()
        t.timeout = 0.2
        let tr = await makeCheck(nudity: .score(0.9), age: StubAge(faceAge: 40, delay: 1.0), thresholds: t)
            .evaluateDetailed(image: blankImage())
        #expect(tr.verdict == .block && tr.failure == .timeout)
    }

    @Test func defaultTimeoutIsTwoSeconds() async {
        #expect(Thresholds().timeout == 2.0)
        let hang = Hang()
        defer { hang.release() }
        let tr = await makeCheck(nudity: .hang(0.0, hang)).evaluateDetailed(image: blankImage())
        #expect(tr.verdict == .block && tr.failure == .timeout)
        #expect(!hang.finished)
    }

    @Test func decoderErrorBlocks() async {
        // A preprocessing/decoder failure surfaces as a thrown detector error ⇒ block.
        struct Decoder: NudityScoring {
            func nudityScore(_ image: CGImage) throws -> Double { throw DetectorError.preprocessing }
        }
        let check = ChildSafetyCheck(detectors: .init(nudity: Decoder(), nudity2: nil, people: StubPeople(), age: StubAge()),
                                     thresholds: Thresholds())
        let tr = await check.evaluateDetailed(image: blankImage())
        #expect(tr.verdict == .block && tr.failure == .preprocessing)
    }

    // MARK: manifest init (M4.T01): missing file ⇒ modelsMissing; wrong sha / unloadable ⇒ modelsDamaged.

    static func fakeInstall(nudity2: Bool = false) throws -> (dir: URL, sha: [String: String]) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "csc-manifest-\(UUID().uuidString)")
        var sha: [String: String] = [:]
        var files = [(ModelManifest.nudityKey, FreepikNudity.relativePath), (ModelManifest.ageKey, MiVOLOAge.relativePath),
                     (ModelManifest.ageBinsKey, SigLIPAgeBins.relativePath)]
        if nudity2 { files.append((ModelManifest.nudity2Key, MarqoNudity.relativePath)) }
        for (key, rel) in files {
            let url = dir.appending(path: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not an onnx file: \(key)".utf8).write(to: url)
            sha[key] = try #require(ModelManifest.sha256Hex(of: url))
        }
        return (dir, sha)
    }

    @Test func manifestMissingFileIsModelsMissing() throws {
        let (dir, sha) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appending(path: MiVOLOAge.relativePath))
        #expect(throws: CheckError.modelsMissing) { _ = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: sha)) }
    }

    @Test func manifestMissingAgeBinsIsModelsMissing() throws {
        let (dir, sha) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appending(path: SigLIPAgeBins.relativePath))
        #expect(throws: CheckError.modelsMissing) { _ = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: sha)) }
    }

    @Test func manifestMissingOptionalFileIsModelsMissing() throws {
        let (dir, sha) = try Self.fakeInstall(nudity2: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appending(path: MarqoNudity.relativePath))
        #expect(throws: CheckError.modelsMissing) { _ = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: sha)) }
    }

    @Test func manifestWrongShaIsModelsDamaged() throws {
        let (dir, sha) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bad = sha
        bad[ModelManifest.ageKey] = String(repeating: "0", count: 64)
        #expect(throws: CheckError.modelsDamaged) { _ = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: bad)) }
        var none = sha
        none[ModelManifest.nudityKey] = nil
        #expect(throws: CheckError.modelsDamaged) { _ = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: none)) }
    }

    @Test func manifestFlippedByteIsModelsDamaged() throws {
        let (dir, sha) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: FreepikNudity.relativePath)
        var d = try Data(contentsOf: url)
        d[0] ^= 0xFF
        try d.write(to: url)
        #expect(throws: CheckError.modelsDamaged) { _ = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: sha)) }
    }

    @Test func manifestUnloadableModelIsModelsDamaged() throws {
        // Hashes match, but the files are not ONNX models ⇒ load fails ⇒ damaged (never a usable check).
        let (dir, sha) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: CheckError.modelsDamaged) {
            _ = try ChildSafetyCheck(manifest: .standard(modelDirectory: dir, sha256: sha), provider: .cpu)
        }
    }

    @Test func manifestBadThresholdsIsModelsDamaged() throws {
        let (dir, sha) = try Self.fakeInstall()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = dir.appending(path: "thresholds.json")
        try Data(#"{"version": 2}"#.utf8).write(to: t)
        let std = ModelManifest.standard(modelDirectory: dir, sha256: sha)
        let m = ModelManifest(nudity: std.nudity, age: std.age, ageBins: std.ageBins, nudity2: nil, sha256: sha, thresholds: t)
        #expect(throws: CheckError.modelsDamaged) { _ = try ChildSafetyCheck(manifest: m, provider: .cpu) }
    }
}
