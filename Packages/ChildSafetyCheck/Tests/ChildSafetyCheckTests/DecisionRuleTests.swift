// Decision rule truth table and face↔body matching (model-matrix §10.3; test-strategy §2).
import CoreGraphics
import Testing
@testable import ChildSafetyCheck

@Suite struct DecisionRuleTests {
    let t = Thresholds()

    @Test func startThresholds() {
        #expect(t.tN == 0.35 && t.tN2 == 0.50 && t.mFace == 7 && t.mBody == 12)
        #expect(t.minFaceConfidence == 0.5 && t.minFaceSide == 24 && t.timeout == 2.0)
    }

    @Test(arguments: [
        (0.34, nil as Double?, false), (0.35, nil, true), (0.9, nil, true),
        (0.10, 0.49, false), (0.10, 0.50, true), (0.36, 0.0, true),
    ])
    func nudeThresholds(n: Double, n2: Double?, expected: Bool) {
        #expect(DecisionRule.isNude(n: n, n2: n2, t) == expected)
    }

    @Test(arguments: [
        ([24.9], [Double](), true), ([25.0], [], false), ([40, 12], [], true),
        ([], [29.9], true), ([], [30.0], false), ([30], [45], false), ([], [], false),
    ])
    func minorMargins(face: [Double], body: [Double], expected: Bool) {
        #expect(DecisionRule.isMinor(faceAges: face, bodyOnlyAges: body, t) == expected)
    }

    @Test(arguments: [
        // (body-only age, P(child + teen), T_age_bins, expected minor)
        (40.0, 0.39, 0.40, false), (40.0, 0.40, 0.40, true), (29.9, 0.0, 0.40, true),
        (40.0, 0.99, Double.infinity, false),  // signal off: the bins never count
    ])
    func bodyOnlyAgeBins(bodyAge: Double, young: Double, tBins: Double, expected: Bool) {
        var t = Thresholds()
        t.tAgeBins = tBins
        #expect(DecisionRule.isMinor(faceAges: [], bodyOnlyAges: [bodyAge], bodyOnlyYoung: [young], t) == expected)
        // Bins only add minors: a young face age stays a minor whatever the bins say.
        #expect(DecisionRule.isMinor(faceAges: [10], bodyOnlyAges: [], bodyOnlyYoung: [0], t))
    }

    @Test func verdictTruthTable() {
        #expect(DecisionRule.verdict(nude: true, minor: true) == .block)
        #expect(DecisionRule.verdict(nude: true, minor: false) == .allow)
        #expect(DecisionRule.verdict(nude: false, minor: true) == .allow)
        #expect(DecisionRule.verdict(nude: false, minor: false) == .allow)
    }

    @Test func faceUsability() {
        #expect(DecisionRule.isUsable(FaceBox(rect: CGRect(x: 0, y: 0, width: 24, height: 30), confidence: 0.5), t))
        #expect(!DecisionRule.isUsable(FaceBox(rect: CGRect(x: 0, y: 0, width: 23, height: 30), confidence: 0.9), t))
        #expect(!DecisionRule.isUsable(FaceBox(rect: CGRect(x: 0, y: 0, width: 40, height: 40), confidence: 0.49), t))
    }

    @Test func ageQueriesCoverFacesAndUnmatchedBodies() {
        let small = FaceBox(rect: CGRect(x: 300, y: 10, width: 10, height: 10), confidence: 0.99)  // unusable
        let good = FaceBox(rect: CGRect(x: 100, y: 100, width: 30, height: 30), confidence: 0.9)
        let b1 = CGRect(x: 80, y: 90, width: 80, height: 200)    // matches `good`
        let b2 = CGRect(x: 280, y: 0, width: 60, height: 200)    // only an unusable face ⇒ body-only
        let qs = DecisionRule.ageQueries(PeopleBoxes(faces: [small, good], bodies: [b1, b2]), t)
        #expect(qs.count == 2)
        #expect(qs.contains(AgeQuery(kind: .face, face: good.rect, body: b1)))
        #expect(qs.contains(AgeQuery(kind: .bodyOnly, face: nil, body: b2)))
    }

    @Test func faceWithoutBodyGetsBlackBody() {
        let good = FaceBox(rect: CGRect(x: 100, y: 100, width: 30, height: 30), confidence: 0.9)
        let qs = DecisionRule.ageQueries(PeopleBoxes(faces: [good], bodies: []), t)
        #expect(qs == [AgeQuery(kind: .face, face: good.rect, body: nil)])
    }
}

/// M4.T01 step 6 truth table: (nude ∈ {no, T_n − ε, T_n, high}) × (faces: none, 40 y, 24 y, 26 y) ×
/// (body-only: none, 29 y, 31 y) × (second nudity signal absent / present), stub numbers only (D-017).
/// Block iff nude and (a face < 18 + m_face or a body-only < 18 + m_body); adult content never blocks.
@Suite struct SpecTruthTableTests {
    static let t = Thresholds()
    static let nudity: [Double] = [0.0, t.tN - 0.0001, t.tN, 0.95]
    static let faces: [Double?] = [nil, 40, 24, 26]
    static let bodyOnly: [Double?] = [nil, 29, 31]

    @Test(arguments: nudity, faces)
    func table(n: Double, faceAge: Double?) async {
        let faceBody = CGRect(x: 0, y: 0, width: 46, height: 64)
        let face = FaceBox(rect: CGRect(x: 10, y: 4, width: 26, height: 26), confidence: 0.9)
        let loneBody = CGRect(x: 200, y: 0, width: 46, height: 64)  // no face inside ⇒ body-only query
        for body in Self.bodyOnly {
            for n2 in [nil, 0.0] as [Double?] {
                var boxes = PeopleBoxes(faces: [], bodies: [])
                if faceAge != nil { boxes.faces.append(face); boxes.bodies.append(faceBody) }
                if body != nil { boxes.bodies.append(loneBody) }
                let check = makeCheck(nudity: .score(n), nudity2: n2.map { .score($0) }, people: StubPeople(boxes: boxes),
                                      age: StubAge(faceAge: faceAge ?? 99, bodyAge: body ?? 99))
                let nude = n >= Self.t.tN
                let minor = (faceAge.map { $0 < 18 + Self.t.mFace } ?? false) || (body.map { $0 < 18 + Self.t.mBody } ?? false)
                let got = await check.evaluate(image: blankImage(256))
                #expect(got == (nude && minor ? .block : .allow),
                        "n=\(n) face=\(String(describing: faceAge)) body=\(String(describing: body)) n2=\(String(describing: n2))")
                if !nude || (faceAge ?? 99) >= 25 && (body ?? 99) >= 30 { #expect(got == .allow) }  // adult or SFW
            }
        }
    }

    @Test func spotChecks() async {
        // adult NSFW (face ≥ 25 / body-only ≥ 30) → allow; SFW at any age → allow; nude + face 24 → block.
        let p = StubPeople(boxes: PeopleBoxes(faces: [oneFace], bodies: [oneBody]))
        #expect(await makeCheck(nudity: .score(0.95), people: p, age: StubAge(faceAge: 26)).evaluate(image: blankImage()) == .allow)
        #expect(await makeCheck(nudity: .score(0.0), people: p, age: StubAge(faceAge: 5)).evaluate(image: blankImage()) == .allow)
        #expect(await makeCheck(nudity: .score(0.95), people: p, age: StubAge(faceAge: 24)).evaluate(image: blankImage()) == .block)
    }
}

/// End-to-end rule through `ChildSafetyCheck` with stub detectors (mocked scores only, D-017).
@Suite struct PipelineTruthTableTests {
    @Test(arguments: [
        // (nudity, faceAge, bodyAge, people?, expected)
        (0.0, 10.0, 10.0, true, ChildSafetyCheck.Verdict.allow),  // not nude, young ⇒ allow
        (0.0, 40.0, 40.0, true, .allow),
        (0.9, 40.0, 40.0, true, .allow),   // nude, adult ⇒ allow (adult content is never blocked)
        (0.9, 24.0, 40.0, true, .block),   // nude, face < 25 ⇒ block
        (0.9, 25.0, 40.0, true, .allow),
        (0.9, 40.0, 10.0, false, .allow),  // nude, nobody detected ⇒ allow
    ])
    func table(n: Double, faceAge: Double, bodyAge: Double, people: Bool, expected: ChildSafetyCheck.Verdict) async {
        let p = people ? StubPeople(boxes: PeopleBoxes(faces: [oneFace], bodies: [oneBody])) : StubPeople()
        let check = makeCheck(nudity: .score(n), people: p, age: StubAge(faceAge: faceAge, bodyAge: bodyAge))
        #expect(await check.evaluate(image: blankImage()) == expected)
    }

    @Test func bodyOnlyMinorBlocksWhenNude() async {
        let p = StubPeople(boxes: PeopleBoxes(faces: [], bodies: [oneBody]))
        #expect(await makeCheck(nudity: .score(0.8), people: p, age: StubAge(bodyAge: 29)).evaluate(image: blankImage()) == .block)
        #expect(await makeCheck(nudity: .score(0.8), people: p, age: StubAge(bodyAge: 30)).evaluate(image: blankImage()) == .allow)
    }

    @Test func ageBinsAddBodyOnlyBlocksWhenNudeOnly() async {
        var t = Thresholds()
        t.tAgeBins = 0.4
        let bodyOnly = StubPeople(boxes: PeopleBoxes(faces: [], bodies: [oneBody]))
        func run(_ n: Double, _ people: StubPeople, _ young: Double) async -> ChildSafetyCheck.Verdict {
            await makeCheck(nudity: .score(n), people: people, age: StubAge(faceAge: 40, bodyAge: 40),
                            ageBins: StubAgeBins(young: young), thresholds: t).evaluate(image: blankImage())
        }
        #expect(await run(0.8, bodyOnly, 0.6) == .block)   // nude, adult body age, bins say young ⇒ block
        #expect(await run(0.8, bodyOnly, 0.2) == .allow)   // nude, adult by both signals ⇒ allow
        #expect(await run(0.1, bodyOnly, 0.9) == .allow)   // not nude ⇒ allow
        // A person WITH a usable face is judged by the face estimate; the bins are not consulted for it.
        #expect(await run(0.8, StubPeople(boxes: PeopleBoxes(faces: [oneFace], bodies: [oneBody])), 0.9) == .allow)
        // Nude with no detectable person stays allow (no "nude + no face ⇒ minor" rule).
        #expect(await run(0.8, StubPeople(), 0.9) == .allow)
    }

    @Test func secondSignalOnlyAddsBlocks() async {
        let young = StubAge(faceAge: 12)
        #expect(await makeCheck(nudity: .score(0.1), nudity2: .score(0.6), age: young).evaluate(image: blankImage()) == .block)
        #expect(await makeCheck(nudity: .score(0.1), nudity2: .score(0.4), age: young).evaluate(image: blankImage()) == .allow)
        #expect(await makeCheck(nudity: .score(0.9), nudity2: .score(0.0), age: young).evaluate(image: blankImage()) == .block)
    }

    @Test func notNudeSkipsAgeWork() async {
        // A failing age estimator must not matter when the image is not nude.
        let check = makeCheck(nudity: .score(0.1), people: StubPeople(fail: true), age: StubAge(fail: true))
        #expect(await check.evaluate(image: blankImage()) == .allow)
    }

    @Test func videoBlocksOnAnyFrameAndEmptyBlocks() async {
        let check = makeCheck(nudity: .score(0.9), age: StubAge(faceAge: 40))
        func stream(_ n: Int) -> AsyncStream<CGImage> {
            AsyncStream { c in (0..<n).forEach { _ in c.yield(blankImage()) }; c.finish() }
        }
        #expect(await check.evaluateVideo(frames: stream(3)) == .allow)
        #expect(await check.evaluateVideo(frames: stream(0)) == .block)
        let young = makeCheck(nudity: .score(0.9), age: StubAge(faceAge: 10))
        #expect(await young.evaluateVideo(frames: stream(3)) == .block)
    }
}
