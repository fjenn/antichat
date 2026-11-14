// M4 review P1-3 / P2-7: live previews. A preview below `preview_min_side_px` is never shown (the check is not valid
// there, so nothing runs); a timeout or detector error while nudity is true or unknown withholds only that preview;
// a rule block stops the job. Stub detectors only (D-017): every image is a blank canvas the stubs never inspect.
import CoreGraphics
import Foundation
import Testing
@testable import ChildSafetyCheck

@Suite struct PreviewRuleTests {
    static func thresholds(minSide: Double = 64, timeout: Double = 2) -> Thresholds {
        var t = Thresholds()
        t.previewMinSide = minSide
        t.timeout = timeout
        return t
    }

    @Test func belowTheValidSizeIsWithheldWithoutRunningAnything() async {
        let ran = Ran()
        let check = makeCheck(nudity: .counting(0, ran), thresholds: Self.thresholds(minSide: 512))
        #expect(await check.evaluatePreview(image: blankImage(128)) == .withhold)
        #expect(ran.count == 0, "no detector ran on a preview the check is not valid for")
        // The final check of the same image is unaffected by the preview size rule.
        #expect(await check.evaluate(image: blankImage(128)) == .allow)
        #expect(ran.count == 1)
    }

    @Test func atTheValidSizeTheRuleDecides() async {
        let t = Self.thresholds(minSide: 64)
        #expect(await makeCheck(nudity: .score(0.1), thresholds: t).evaluatePreview(image: blankImage(64)) == .show)
        // nude ∧ minor (mocked scores) ⇒ the job stops, as before.
        #expect(await makeCheck(nudity: .score(0.9), age: StubAge(faceAge: 10), thresholds: t)
            .evaluatePreview(image: blankImage(64)) == .block)
        #expect(await makeCheck(nudity: .score(0.9), age: StubAge(faceAge: 40), thresholds: t)
            .evaluatePreview(image: blankImage(64)) == .show)
    }

    @Test func detectorErrorWhileNudeOrUnknownWithholdsOnlyThePreview() async {
        let t = Self.thresholds(minSide: 64)
        #expect(await makeCheck(nudity: .fail, thresholds: t).evaluatePreview(image: blankImage(64)) == .withhold)
        #expect(await makeCheck(nudity: .score(0.9), age: StubAge(fail: true), thresholds: t)
            .evaluatePreview(image: blankImage(64)) == .withhold)
        // The same errors on a final output still block (unchanged).
        #expect(await makeCheck(nudity: .fail, thresholds: t).evaluate(image: blankImage(64)) == .block)
    }

    @Test func timeoutWithholdsOnlyThePreviewAndIsNotRetried() async {
        let hang = Hang()
        defer { hang.release() }
        // Own lane: the hung detector must not hold the shared lane for other suites.
        let check = ChildSafetyCheck(
            detectors: .init(nudity: StubNudity(mode: .hang(0.1, hang)), nudity2: nil,
                             people: StubPeople(boxes: PeopleBoxes(faces: [oneFace], bodies: [oneBody])), age: StubAge()),
            thresholds: Self.thresholds(minSide: 64, timeout: 0.2), queueWait: 0.2,
            lane: DispatchQueue(label: "PreviewRuleTests.lane", qos: .userInitiated))
        #expect(await check.evaluatePreview(image: blankImage(64)) == .withhold)
        #expect(check.timeoutRetries == 0, "a preview is not re-checked; it is only not shown")
    }

    @Test func traceMapping() {
        typealias C = ChildSafetyCheck
        #expect(C.previewVerdict(C.Trace(verdict: .allow)) == .show)
        #expect(C.previewVerdict(C.Trace(verdict: .block)) == .block)
        #expect(C.previewVerdict(C.Trace(verdict: .block, failure: .timeout)) == .withhold)
        #expect(C.previewVerdict(C.Trace(verdict: .allow, failure: .timeout)) == .show)
        let t = Self.thresholds(minSide: 512)
        #expect(!C.previewCheckable(width: 128, height: 128, t))
        #expect(!C.previewCheckable(width: 1024, height: 500, t), "the shorter side decides")
        #expect(C.previewCheckable(width: 512, height: 768, t))
    }

    @Test func thresholdsFileCarriesThePreviewSize() throws {
        let shipped = try Thresholds.bundled()
        #expect(shipped.version >= 4 && shipped.previewMinSide.isFinite && shipped.previewMinSide > 0)
        // A file without the key (before v4) shows no preview at all (fail closed).
        let v3 = #"{"version":3,"T_n":0.4,"T_n2":null,"m_face":8,"m_body":12,"face_min_conf":0.5,"face_min_side_px":24,"face_in_body_min":0.6,"timeout_ms":1500}"#
        #expect(try Thresholds.decode(Data(v3.utf8)).previewMinSide == .infinity)
        let v4 = v3.replacingOccurrences(of: #""timeout_ms":1500"#, with: #""timeout_ms":1500,"preview_min_side_px":384"#)
        #expect(try Thresholds.decode(Data(v4.utf8)).previewMinSide == 384)
        #expect(throws: (any Error).self) {
            _ = try Thresholds.decode(Data(v3.replacingOccurrences(of: #""timeout_ms":1500"#, with: #""timeout_ms":1500,"preview_min_side_px":-1"#).utf8))
        }
    }

    /// fix/t05-video: the public size pre-check is exactly the shipped rule (never looser than `evaluatePreview`).
    @Test func shippedPreviewSizeMatchesTheBundledThresholds() throws {
        let shipped = try Thresholds.bundled()
        #expect(ChildSafetyCheck.shippedPreviewMinSide == shipped.previewMinSide)
        let side = Int(shipped.previewMinSide)
        for (w, h) in [(side, side), (side - 1, side * 2), (side * 2, side - 1), (832, 480), (1280, 704), (931, 512), (160, 160)] {
            #expect(ChildSafetyCheck.previewSizeCheckable(width: w, height: h)
                    == ChildSafetyCheck.previewCheckable(width: w, height: h, shipped), "\(w)x\(h)")
        }
    }
}
