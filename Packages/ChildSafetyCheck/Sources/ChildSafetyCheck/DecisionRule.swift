// Decision rule, exactly as docs/research/06-models/model-matrix.md §10.3:
//
//   nude  = (n ≥ T_n) or (n2 ≥ T_n2)
//   minor = any(face age < 18 + m_face)
//        or any(person without a usable face: body-only age < 18 + m_body  or  age-bin P(child + teen) ≥ T_age_bins)
//   BLOCK iff nude and minor; any detector error or timeout while nude is true or unknown ⇒ BLOCK.
//
// Pure functions only, so the truth table is unit-tested with stub scores (D-017: the conjunction
// is tested with mocked detector scores only, never with images).
import CoreGraphics

/// One detected face, in pixel coordinates with a top-left origin.
package struct FaceBox: Sendable, Equatable {
    package var rect: CGRect
    package var confidence: Double
    package init(rect: CGRect, confidence: Double) {
        self.rect = rect
        self.confidence = confidence
    }
}

/// Faces and person (body) rectangles found in one image, pixel coordinates, top-left origin.
package struct PeopleBoxes: Sendable, Equatable {
    package var faces: [FaceBox]
    package var bodies: [CGRect]
    package init(faces: [FaceBox], bodies: [CGRect]) {
        self.faces = faces
        self.bodies = bodies
    }
}

/// One age query: a face with its matched body (either may be absent; absent = black crop).
package struct AgeQuery: Sendable, Equatable {
    package enum Kind: Sendable, Equatable { case face, bodyOnly }
    package var kind: Kind
    package var face: CGRect?
    package var body: CGRect?
}

package enum DecisionRule {
    package static func isNude(n: Double, n2: Double?, _ t: Thresholds) -> Bool {
        if n >= t.tN { return true }
        if let n2, n2 >= t.tN2 { return true }
        return false
    }

    package static func isUsable(_ face: FaceBox, _ t: Thresholds) -> Bool {
        face.confidence >= t.minFaceConfidence && min(face.rect.width, face.rect.height) >= t.minFaceSide
    }

    /// The age estimates the rule needs for one image: every usable face (with its matched body,
    /// or none ⇒ black body), and every body that no usable face matched (body-only).
    package static func ageQueries(_ people: PeopleBoxes, _ t: Thresholds) -> [AgeQuery] {
        let usable = people.faces.filter { isUsable($0, t) }.map(\.rect)
        let matched = FaceBodyMatcher.match(faces: usable, bodies: people.bodies, minFaceInBody: t.minFaceInBody)
        var queries = zip(usable, matched).map { face, bi in
            AgeQuery(kind: .face, face: face, body: bi.map { people.bodies[$0] })
        }
        let usedBodies = Set(matched.compactMap { $0 })
        for (bi, body) in people.bodies.enumerated() where !usedBodies.contains(bi) {
            queries.append(AgeQuery(kind: .bodyOnly, face: nil, body: body))
        }
        return queries
    }

    /// True if any estimate is under the adult boundary plus its margin, or (body-only) the age-bin
    /// classifier puts at least `T_age_bins` on Child 0–12 + Teenager 13–20. The bins only add minors.
    package static func isMinor(faceAges: [Double], bodyOnlyAges: [Double], bodyOnlyYoung: [Double] = [],
                                _ t: Thresholds) -> Bool {
        faceAges.contains { $0 < t.adultAge + t.mFace } || bodyOnlyAges.contains { $0 < t.adultAge + t.mBody }
            || bodyOnlyYoung.contains { $0 >= t.tAgeBins }
    }

    package static func verdict(nude: Bool, minor: Bool) -> ChildSafetyCheck.Verdict {
        nude && minor ? .block : .allow
    }
}
