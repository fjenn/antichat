// Face↔body matching (model-matrix §10.3; A-M0-T08b b): IoU table, containment filter, one-to-one.
import CoreGraphics
import Testing
@testable import ChildSafetyCheck

@Suite struct FaceBodyMatcherTests {
    static let unit = CGRect(x: 0, y: 0, width: 10, height: 10)

    @Test(arguments: [
        (unit, unit, 1.0),
        (unit, CGRect(x: 20, y: 20, width: 5, height: 5), 0.0),            // disjoint
        (unit, CGRect(x: 10, y: 0, width: 10, height: 10), 0.0),           // touching edge
        (unit, CGRect(x: 5, y: 0, width: 10, height: 10), 50.0 / 150.0),   // half overlap
        (unit, CGRect(x: 0, y: 0, width: 20, height: 20), 100.0 / 400.0),  // contained
        (unit, CGRect(x: 5, y: 5, width: 10, height: 10), 25.0 / 175.0),   // corner overlap
        (unit, CGRect.zero, 0.0),
    ])
    func iouTable(a: CGRect, b: CGRect, expected: Double) {
        #expect(abs(FaceBodyMatcher.iou(a, b) - expected) < 1e-9)
        #expect(abs(FaceBodyMatcher.iou(b, a) - expected) < 1e-9)  // symmetric
    }

    @Test func faceInBodyFraction() {
        let face = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(FaceBodyMatcher.faceInBody(face, CGRect(x: -5, y: -5, width: 30, height: 30)) == 1)
        #expect(abs(FaceBodyMatcher.faceInBody(face, CGRect(x: 4, y: 0, width: 30, height: 30)) - 0.6) < 1e-9)
        #expect(FaceBodyMatcher.faceInBody(face, CGRect(x: 50, y: 50, width: 5, height: 5)) == 0)
        #expect(FaceBodyMatcher.faceInBody(.zero, face) == 0)
    }

    @Test func matchingPicksTightestContainingBody() {
        let face = CGRect(x: 100, y: 100, width: 30, height: 30)
        let tight = CGRect(x: 80, y: 90, width: 70, height: 200)
        let huge = CGRect(x: 0, y: 0, width: 600, height: 600)  // also contains the face
        let other = CGRect(x: 400, y: 100, width: 70, height: 200)
        #expect(FaceBodyMatcher.match(faces: [face], bodies: [huge, other, tight], minFaceInBody: 0.6) == [2])
    }

    @Test func containmentBelowMinimumDoesNotMatch() {
        let face = CGRect(x: 0, y: 0, width: 10, height: 10)
        let body = CGRect(x: 5, y: 0, width: 40, height: 80)  // 50% of the face inside
        #expect(FaceBodyMatcher.match(faces: [face], bodies: [body], minFaceInBody: 0.6) == [nil])
        #expect(FaceBodyMatcher.match(faces: [face], bodies: [body], minFaceInBody: 0.5) == [0])
    }

    @Test func matchingIsOneToOne() {
        let f1 = CGRect(x: 100, y: 100, width: 30, height: 30)
        let f2 = CGRect(x: 110, y: 105, width: 28, height: 28)
        let body = CGRect(x: 80, y: 90, width: 80, height: 200)
        let m = FaceBodyMatcher.match(faces: [f1, f2], bodies: [body], minFaceInBody: 0.6)
        #expect(m.compactMap { $0 } == [0])
        #expect(m.filter { $0 == nil }.count == 1)
    }

    @Test func twoPeopleEachGetTheirOwnBody() {
        let f1 = CGRect(x: 20, y: 10, width: 20, height: 20), b1 = CGRect(x: 0, y: 0, width: 60, height: 160)
        let f2 = CGRect(x: 220, y: 10, width: 20, height: 20), b2 = CGRect(x: 200, y: 0, width: 60, height: 160)
        #expect(FaceBodyMatcher.match(faces: [f1, f2], bodies: [b2, b1], minFaceInBody: 0.6) == [1, 0])
        #expect(FaceBodyMatcher.match(faces: [], bodies: [b1], minFaceInBody: 0.6) == [])
        #expect(FaceBodyMatcher.match(faces: [f1], bodies: [], minFaceInBody: 0.6) == [nil])
    }
}
