// Face and person detection with Apple Vision (system framework, no download; model-matrix §10.2).
import CoreGraphics
import Vision

package protocol PeopleDetecting: Sendable {
    func detect(_ image: CGImage) throws -> PeopleBoxes
}

package struct VisionPeople: PeopleDetecting {
    package init() {}

    package func detect(_ image: CGImage) throws -> PeopleBoxes {
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([faces, humans])
        } catch {
            throw DetectorError.inference("vision: \(error.localizedDescription)")
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision boxes are normalised with a bottom-left origin; convert to top-left pixels.
        func px(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
        }
        return PeopleBoxes(
            faces: (faces.results ?? []).map { FaceBox(rect: px($0.boundingBox), confidence: Double($0.confidence)) },
            bodies: (humans.results ?? []).map { px($0.boundingBox) }
        )
    }
}
