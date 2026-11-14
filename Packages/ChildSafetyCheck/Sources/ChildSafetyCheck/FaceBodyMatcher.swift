// Face↔body matching for the decision rule (model-matrix §10.3; A-M0-T08b b). Pure geometry.
import CoreGraphics

package enum FaceBodyMatcher {
    /// Intersection-over-union of two rectangles (0 when disjoint).
    package static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - inter
        return union > 0 ? inter / union : 0
    }

    /// Fraction of `face` that lies inside `body` (intersection over the face area).
    package static func faceInBody(_ face: CGRect, _ body: CGRect) -> Double {
        let i = face.intersection(body)
        guard !i.isNull, i.width > 0, i.height > 0, face.width > 0, face.height > 0 else { return 0 }
        return Double(i.width * i.height) / Double(face.width * face.height)
    }

    /// Greedy one-to-one face↔body matching. A face box is tiny next to its body box, so raw IoU is
    /// small for every correct pair; the candidate filter is face-in-body containment ≥ `minFaceInBody`,
    /// and among candidates the pair with the highest IoU (the tightest body around the face) wins.
    /// Returns, for each face index, the matched body index or nil.
    package static func match(faces: [CGRect], bodies: [CGRect], minFaceInBody: Double) -> [Int?] {
        var pairs: [(f: Int, b: Int, score: Double)] = []
        for (fi, f) in faces.enumerated() {
            for (bi, b) in bodies.enumerated() where faceInBody(f, b) >= minFaceInBody {
                pairs.append((fi, bi, iou(f, b)))
            }
        }
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : ($0.f, $0.b) < ($1.f, $1.b) }
        var result = [Int?](repeating: nil, count: faces.count)
        var usedBodies = Set<Int>()
        for p in pairs where result[p.f] == nil && !usedBodies.contains(p.b) {
            result[p.f] = p.b
            usedBodies.insert(p.b)
        }
        return result
    }
}
