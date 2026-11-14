// Prints "<face count>\t<path>" per image using Apple Vision (fixture tooling, M0.T01 step 6).
import Foundation
import Vision

for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let request = VNDetectFaceRectanglesRequest()
    let handler = VNImageRequestHandler(url: url)
    var n = 0
    if (try? handler.perform([request])) != nil {
        n = request.results?.count ?? 0
    }
    print("\(n)\t\(path)")
}
